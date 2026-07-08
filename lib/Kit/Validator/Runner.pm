package Kit::Validator::Runner;
use v5.20;
use warnings;

use Kit::Validator::Environment;
use Kit::Validator::Fixture;
use Kit::Validator::Prune;
use Kit::Validator::Bootstrap;
use Kit::Validator::Runner::Cmd;

use File::Temp qw/tempdir/;
use File::Basename qw/basename/;

# Load Genesis lazily.  Framework unit tests import the Runner but
# should not require the Genesis runtime; only Runner->run does.
my $GENESIS_LOADED;
sub _require_genesis {
	return if $GENESIS_LOADED;
	eval {
		require Genesis;
		require Service::Vault::Local;
		1;
	} or die
		"Kit::Validator::Runner: Genesis's lib is not loadable.\n".
		"Kit-validator requires 'use Genesis;' and 'use Service::Vault::Local;'\n".
		"to succeed.  Set PERL5LIB to include the Genesis checkout's lib/\n".
		"directory, or run on a kit CI image that already ships Genesis.\n".
		"Underlying error: $@\n";
	$GENESIS_LOADED = 1;
}

# run - orchestrate one environment through the validation pipeline
# and emit a Test::More subtest reporting the outcome.
#
# On the assertion path, this shells out to `genesis manifest` (via
# Genesis::run) for realistic CLI-surface exercise.  On the
# diagnostic path (when a shell-out fails), it uses in-process
# Genesis::Env API calls to explain WHY -- schema errors, missing
# secrets, hook stack traces -- rather than dumping raw stderr.
sub run {
	my ($class, $env, %opts) = @_;

	my $kit_dir = $opts{kit_dir}
		or die "Kit::Validator::Runner->run: kit_dir is required\n";

	# Late-load Test::More so the module can be `use`d in contexts that
	# never call ->run (e.g. inline docs, package_loaded checks).
	require Test::More;
	Test::More::subtest("env: ".$env->name => sub {
		my $ok = eval { $class->_execute($env, kit_dir => $kit_dir); 1 };
		unless ($ok) {
			my $err = $@;
			Test::More::fail("pipeline: ".$env->name);
			Test::More::diag($err);
		}
	});
}

sub _execute {
	my ($class, $env, %opts) = @_;
	_require_genesis();

	my $kit_dir     = $opts{kit_dir};
	my $kit_name    = _detect_kit_name($kit_dir);
	my $fixture_dir = "$kit_dir/spec";
	my $fx          = Kit::Validator::Fixture->new(kit_dir => $kit_dir);

	# 1. Ephemeral workdir with scoped HOME.
	my $workdir = tempdir(
		'kv-XXXXXX', DIR => File::Spec->tmpdir, CLEANUP => 1,
	);
	local $ENV{HOME} = $workdir;
	local $ENV{XDG_CONFIG_HOME} = "$workdir/.config";

	# 2. Ephemeral vault via Service::Vault::Local.  Alias PID-scoped
	# so parallel prove workers don't collide.
	my $vault_alias = 'kv-'.$env->name.'-'.$$;
	my $vault = Service::Vault::Local->create($vault_alias);
	my $shutdown_guard = _shutdown_guard($vault);

	# 3. Testing-mode env vars carried into every genesis subcommand.
	local %ENV = (%ENV, %{Kit::Validator::Runner::Cmd::testing_env(env => $env)});

	# 4. git identity in the scoped HOME.
	_seed_git_identity($workdir);

	# 5. genesis init in the workdir, linking against the kit under test.
	# Pass the vault's URL, not its alias: Service::Vault::Remote->find
	# keys lookup on URL, and passing the alias name produces the opaque
	# "Can't call method 'connect_and_validate' on undef" downstream.
	_run_cmd(
		Kit::Validator::Runner::Cmd::genesis_init_cmd(
			kit_name => $kit_name,
			kit_dir  => $kit_dir,
			workdir  => $workdir,
			vault    => $vault->url,
		),
		onfailure => "genesis init failed for ".$env->name,
	);

	# 6. Copy fixture files (env yml, ops yml files).
	_copy_env_fixture($fx, $env, $workdir);
	_copy_ops_fixtures($fx, $env, $workdir);

	# 7. Import exodus stub if present.
	_import_exodus_if_present($fx, $env, $vault);

	# 8. Vault-cache bootstrap (only if spec/vault/<env>.yml absent).
	_bootstrap_vault_cache_if_missing($fx, $env, $kit_name, $vault);

	# 9. Always import the (now-present) vault cache.
	_import_vault_cache($fx, $env, $vault);

	# 10. genesis check with output_matchers awareness.
	my $check_out = _run_genesis_step(
		cmd       => Kit::Validator::Runner::Cmd::genesis_check_cmd(
			env => $env, fixture_dir => $fixture_dir),
		matcher   => $env->output_matchers->{genesis_check},
		step_name => 'genesis check',
	);

	# 11. genesis manifest with output_matchers awareness.
	my $manifest_yaml = _run_genesis_step(
		cmd       => Kit::Validator::Runner::Cmd::genesis_manifest_cmd(
			env => $env, fixture_dir => $fixture_dir),
		matcher   => $env->output_matchers->{genesis_manifest},
		step_name => 'genesis manifest',
		capture   => 1,
	);

	# If the env expected the manifest step to fail on output_matchers,
	# the manifest_yaml is undef; skip the remainder of the pipeline.
	return unless defined $manifest_yaml;

	# 12. Prune volatile keys; peel off bosh-variables.
	# Parse via Genesis::load_yaml (spruce-shell under the hood).
	my $manifest = Genesis::load_yaml($manifest_yaml);
	my $is_proto = _env_has_proto_feature($env, $workdir);
	my ($pruned, $bosh_vars)
		= Kit::Validator::Prune::prune_manifest($manifest, {is_proto => $is_proto});

	# 13. Credhub-stub bootstrap.
	_bootstrap_credhub_stub_if_missing($fx, $env, $pruned, $workdir);

	# 14. bosh int interpolation.
	my $rendered = _interpolate($fx, $env, $pruned, $bosh_vars, $workdir);

	# 15. Golden bootstrap or spruce-diff assertion.
	_compare_or_bootstrap_golden($fx, $env, $rendered);
}

# --------------------------------------------------------------------
# The subroutines below are stubs marking pipeline stages for the
# BOSH-pilot phase.  Each has a defined signature and known behavior
# from testkit; the implementation lands during pilot integration
# testing against real fixtures.

# _run_cmd - splat a Runner::Cmd argv into Genesis::run's calling
# convention.  Genesis::run(prog, @args) auto-wraps the first arg
# as a bash `-c` string and appends `"${@}"` to consume the rest,
# giving us argv-style dispatch.  Extra opts (onfailure, stderr,
# stdin, ...) go in the leading hashref.
sub _run_cmd {
	my ($argv, %opts) = @_;
	die "_run_cmd: expected arrayref argv, got ".ref($argv)."\n"
		unless ref $argv eq 'ARRAY' && @$argv;
	return Genesis::run(\%opts, @$argv);
}

sub _detect_kit_name {
	my ($kit_dir) = @_;
	# Kits ship a kit.yml at the repo root.  Parse via Genesis's
	# spruce-shell helper -- avoids a hard dep on YAML::PP that
	# Genesis itself has already opted out of.
	my $kit_yml = "$kit_dir/kit.yml";
	die "Kit::Validator::Runner: no kit.yml at $kit_yml\n"
		unless -f $kit_yml;
	my $kit = Genesis::load_yaml_file($kit_yml);
	my $name = $kit->{name}
		or die "Kit::Validator::Runner: kit.yml has no 'name'\n";
	return $name;
}

sub _shutdown_guard {
	my ($vault) = @_;
	# Returns a scope-scoped guard: a blessed hashref whose DESTROY
	# shuts down the local vault, ensuring cleanup on both normal
	# return and die().
	return bless {vault => $vault}, 'Kit::Validator::Runner::_Guard';
}

package Kit::Validator::Runner::_Guard;
sub DESTROY {
	my ($self) = @_;
	eval { $self->{vault}->shutdown } if $self->{vault};
}
package Kit::Validator::Runner;

sub _seed_git_identity {
	my ($workdir) = @_;
	my $gc = "$workdir/.gitconfig";
	open my $fh, '>', $gc or die "cannot write $gc: $!";
	print $fh "[user]\n\tname = Kit Validator\n\temail = validator\@localhost\n";
	close $fh;
}

sub _copy_env_fixture {
	my ($fx, $env, $workdir) = @_;
	my $src = $fx->path('deployments', $env->name);
	die "spec/deployments/".$env->name.".yml is missing\n" unless -f $src;
	require File::Copy;
	File::Copy::copy($src, "$workdir/deployments/".$env->name.".yml")
		or die "copy failed: $!";
}

sub _copy_ops_fixtures {
	my ($fx, $env, $workdir) = @_;
	return unless @{$env->ops};
	require File::Copy;
	require File::Path;
	File::Path::make_path("$workdir/deployments/ops");
	for my $op (@{$env->ops}) {
		File::Copy::copy(
			$fx->path('ops', $op),
			"$workdir/deployments/ops/$op.yml",
		) or die "copy of ops/$op failed: $!";
	}
}

sub _import_exodus_if_present {
	my ($fx, $env, $vault) = @_;
	return unless $env->exodus;
	# TBD: import <spec/exodus/<name>.yml> under secret/exodus/<env>.
	# Deferred to BOSH-pilot integration work.
}

sub _bootstrap_vault_cache_if_missing {
	my ($fx, $env, $kit_name, $vault) = @_;
	return if $fx->exists('vault', $env->name);
	# TBD: run check-secrets + add-secrets + export + tokenize + write.
	# Deferred to BOSH-pilot integration work.
}

sub _import_vault_cache {
	my ($fx, $env, $vault) = @_;
	# TBD: safe import spec/vault/<env>.yml into the running vault.
	# Deferred to BOSH-pilot integration work.
}

sub _run_genesis_step {
	my (%o) = @_;
	# TBD: shell out via Genesis::run, capture stdout+stderr, apply
	# output_matcher regex if set, return output or undef.
	# Deferred to BOSH-pilot integration work.
	die "_run_genesis_step: not implemented (deferred to pilot integration)\n";
}

sub _env_has_proto_feature {
	my ($env, $workdir) = @_;
	# TBD: parse deployments/<env>.yml, look at kit.features for 'proto'.
	# Deferred to BOSH-pilot integration work.
	return 0;
}

sub _bootstrap_credhub_stub_if_missing {
	my ($fx, $env, $manifest, $workdir) = @_;
	return if $fx->exists('credhub', $env->name);
	# TBD: only fires when manifest has variables:. Run bosh int
	# --vars-store, then tokenize with Bootstrap::tokenize_credhub_vars.
	# Deferred to BOSH-pilot integration work.
}

sub _interpolate {
	my ($fx, $env, $manifest, $bosh_vars, $workdir) = @_;
	# TBD: write $manifest + $bosh_vars to tempfiles, run bosh int.
	# Deferred to BOSH-pilot integration work.
	die "_interpolate: not implemented (deferred to pilot integration)\n";
}

sub _compare_or_bootstrap_golden {
	my ($fx, $env, $rendered) = @_;
	if (!$fx->exists('results', $env->name)) {
		# First run: materialize the golden and pass.
		$fx->write('results', $env->name, $rendered);
		return;
	}
	# TBD: shell to `spruce diff <golden> <tmp/actual>`, fail with the
	# diff body on nonzero rc.
	# Deferred to BOSH-pilot integration work.
	die "_compare_or_bootstrap_golden: not implemented (deferred to pilot integration)\n";
}

1;

__END__

=head1 NAME

Kit::Validator::Runner - Per-environment orchestrator

=head1 SYNOPSIS

  use Kit::Validator::Runner;
  Kit::Validator::Runner->run($env, kit_dir => '.');

=head1 DESCRIPTION

Drives one environment through the 15-stage pipeline that mirrors the
Go testkit's C<Test()> behavior.  Emits a Test::More subtest reporting
pass or fail; failure diagnostics include diagnostics gathered
in-process via C<Genesis::Env> (not raw stderr).

=head1 RUNTIME REQUIREMENTS

C<Genesis> and C<Service::Vault::Local> must be loadable.  On kit CI
images this is already the case.  Locally, set C<PERL5LIB> to include
the Genesis checkout's C<lib/> directory.

=head1 STAGE COMPLETION

As of this commit, the orchestrator's outer skeleton, workdir + vault
setup, fixture copying, prune stage, and golden-bootstrap-when-absent
are wired.  The following stages are stubbed and will be filled in
during BOSH-pilot integration work:

=over 4

=item * C<_import_exodus_if_present>

=item * C<_bootstrap_vault_cache_if_missing>

=item * C<_import_vault_cache>

=item * C<_run_genesis_step> (the shell-out to genesis check / manifest)

=item * C<_env_has_proto_feature>

=item * C<_bootstrap_credhub_stub_if_missing>

=item * C<_interpolate>

=item * C<_compare_or_bootstrap_golden> (compare arm; bootstrap arm is done)

=back

=cut
