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

# _require_genesis - guarantee that Genesis's Perl lib is loadable and
# consistent with the genesis binary that the pipeline will shell out
# to.
#
# Coupling problem this solves: `~/.genesis/lib/` reflects whichever
# genesis binary was last invoked on this box.  If our Perl loads
# Genesis modules from there and then we shell to a *different* genesis
# binary (e.g. via KIT_VALIDATOR_GENESIS pointing at a locally-packed
# g32), that binary re-extracts to the same directory mid-run and we
# end up straddling two versions -- some modules from image A already
# in %INC, some file-system state now reflects image B.
#
# Fix: at load time, peek at the target binary's embedded checksum
# (the first line after __DATA__ in the self-extracting stub) and
# compare against `<genesis_home>/checksum`.  If they match, the
# extract already reflects the binary we intend to test with -- no
# action needed.  If they don't (or the checksum file is absent), run
# `<binary> --version >/dev/null` to force the binary's own extract
# routine; the resulting state is authoritative for our subsequent
# module loads.
#
# Also honors PERL5LIB / an already-visible Genesis on @INC as a
# fallback path -- useful for dev iteration inside the studio, where
# the lib comes from a git checkout, not from a genesis binary extract.
sub _require_genesis {
	return if $GENESIS_LOADED;

	# Fast path: if Genesis is already reachable via @INC (dev
	# iteration with PERL5LIB set), use it -- but only if it loads
	# cleanly.  Any load error falls through to the extract path.
	if (eval { require Genesis; require Service::Vault::Local; 1 }) {
		$GENESIS_LOADED = 1;
		return;
	}
	my $inline_err = $@;

	my $genesis_home = $ENV{GENESIS_HOME} || ($ENV{HOME}//'').'/.genesis';
	my $genesis_lib  = "$genesis_home/lib";
	my $binary       = $ENV{KIT_VALIDATOR_GENESIS} || 'genesis';

	unless (_extract_is_current($binary, $genesis_home)) {
		my $rc = system("$binary --version >/dev/null 2>&1");
		die
			"Kit::Validator::Runner: could not invoke '$binary' to prepare "
			."the Genesis Perl lib.\n".
			"Genesis binary exited with status $rc.\n".
			"Either put a genesis binary on PATH, set "
			."KIT_VALIDATOR_GENESIS to point at one, or set PERL5LIB to "
			."include a Genesis checkout's lib/ directory.\n".
			"Inline-load error was: $inline_err\n"
			if $rc != 0;
	}

	die "Kit::Validator::Runner: Genesis lib directory not present at "
		."$genesis_lib after invoking '$binary'.\n"
		unless -d $genesis_lib;

	require lib;
	lib->import($genesis_lib);

	eval { require Genesis; require Service::Vault::Local; 1 } or die
		"Kit::Validator::Runner: Genesis modules could not be loaded "
		."from $genesis_lib after successful extract.\nUnderlying error: $@\n";
	$GENESIS_LOADED = 1;
}

# _extract_is_current - probe whether ~/.genesis/checksum matches the
# checksum embedded in the target binary's self-extracting stub.
# Returns 1 when we can safely skip the `<binary> --version` invocation
# because the extract is already the right version; returns 0 on any
# uncertainty (missing files, stub in an unexpected format, etc) --
# the caller then falls through to invoking the binary, which does its
# own more thorough check-and-extract.
sub _extract_is_current {
	my ($binary, $genesis_home) = @_;

	my $checksum_file = "$genesis_home/checksum";
	return 0 unless -f $checksum_file;
	my $have = do {
		open my $fh, '<', $checksum_file or return 0;
		local $/;
		<$fh>;
	};
	return 0 unless defined $have;
	$have =~ s/\s+//g;
	return 0 unless length $have;

	my $binary_path = _resolve_binary_path($binary);
	return 0 unless $binary_path && -f $binary_path;

	# The self-extracting stub is a Perl script with an SHA1 as the
	# first line after `__DATA__`.  If the format ever changes -- or
	# KIT_VALIDATOR_GENESIS points at something entirely non-Perl --
	# this probe returns 0 and we fall through to `<binary> --version`,
	# which is the authoritative check.  Cap the scan at 4KB so we
	# never slurp a large compiled binary looking for a marker that
	# will never appear.
	open my $bfh, '<', $binary_path or return 0;
	my $seen = 0;
	while (my $line = <$bfh>) {
		$seen += length($line);
		if ($seen > 4096) { close $bfh; return 0 }
		chomp $line;
		next unless $line eq '__DATA__';
		my $want = <$bfh>;
		close $bfh;
		return 0 unless defined $want;
		$want =~ s/\s+//g;
		return $want eq $have ? 1 : 0;
	}
	close $bfh;
	return 0;
}

sub _resolve_binary_path {
	my ($name) = @_;
	return $name if $name =~ m{/} && -x $name;
	for my $dir (split /:/, ($ENV{PATH}//'')) {
		next unless length $dir;
		return "$dir/$name" if -x "$dir/$name";
	}
	return undef;
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
		if ($ok) {
			Test::More::pass("pipeline: ".$env->name);
		} else {
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

	# 9. Always import the (now-present) tokenized cache back into the
	# vault, replacing the real generated values from bootstrap with
	# the `<!{meta.vault}/...!>` markers that testkit-style specs use.
	# This is what lets golden manifests be committed to git safely --
	# they carry the tokens, not real secret material, and every
	# subsequent smoke run replays the same tokens through spruce.
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
	# Force HOME explicitly through the opts.env layer -- Genesis::run
	# has a `local %ENV = %ENV` that inherits from caller, but a
	# subprocess's HOME can otherwise drift if any Genesis::* helper
	# unsets it along the way, and a lost HOME breaks safe/.saferc
	# lookup silently (all_vaults returns []).
	$opts{env} = {%{$opts{env}//{}}, HOME => $ENV{HOME}};
	# Default the subprocess CWD to $HOME (which the Runner has already
	# scoped to the per-env workdir), so `--cwd deployments/` and
	# similar relative paths resolve.  Callers may still override via
	# an explicit `dir => ...`.
	$opts{dir} //= $ENV{HOME};
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
	my $stub = $fx->path('exodus', $env->exodus);
	die "spec/exodus/".$env->exodus.".yml is missing (declared by env "
		.$env->name.")\n"
		unless -f $stub;

	# The stub is keyed by service type at the top level; each nested
	# tree becomes flat fields under secret/exodus/<env>/<type>.  Genesis
	# then reads with unflatten() on the far side, so nested paths
	# rejoin transparently.
	#
	# Example:
	#   old-version.yml:  { bosh: { kit_version: 2.3.0 } }
	#   =>  safe set secret/exodus/upgrade/bosh kit_version=2.3.0
	require Genesis;
	my $exodus = Genesis::load_yaml_file($stub);
	die "spec/exodus/".$env->exodus.".yml is not a hash\n"
		unless ref($exodus) eq 'HASH';

	for my $type (keys %$exodus) {
		my $subtree = $exodus->{$type};
		next unless ref($subtree) eq 'HASH';
		my %flat = _flatten_leaves($subtree);
		next unless keys %flat;
		my $path = 'secret/exodus/'.$env->name.'/'.$type;
		# `safe set` accepts key=value pairs positionally.
		_run_cmd(
			['safe', 'set', $path, map { "$_=$flat{$_}" } keys %flat],
			stderr => '&1',
		);
	}
}

# _flatten_leaves - depth-first walk a nested hash, joining keys with
# '.' so the vault entry mirrors what unflatten() expects on the read
# side.  Arrays are stringified as-is; nulls become empty strings.
sub _flatten_leaves {
	my ($tree, $prefix) = @_;
	$prefix //= '';
	my %out;
	for my $key (keys %$tree) {
		my $val = $tree->{$key};
		my $new_key = length($prefix) ? "$prefix.$key" : $key;
		if (ref($val) eq 'HASH') {
			%out = (%out, _flatten_leaves($val, $new_key));
		} else {
			$out{$new_key} = defined($val) ? $val : '';
		}
	}
	return %out;
}

sub _bootstrap_vault_cache_if_missing {
	my ($fx, $env, $kit_name, $vault) = @_;
	return if $fx->exists('vault', $env->name);

	# Ask genesis for the "provided" secret paths that need external
	# seeding (things a real deploy would supply -- IaaS creds, TLS
	# CA overrides, etc.).  Everything else (random passwords, self-
	# signed certs, etc.) genesis will generate via add-secrets.
	my $checksecrets = _run_cmd(
		Kit::Validator::Runner::Cmd::genesis_check_secrets_cmd(env => $env),
		stderr => '&1',
	);
	# _run_cmd returns whatever Genesis::run returns; when it's scalar,
	# that's the combined output.  Parse for `provided:` lines emitted
	# by check-secrets (path:key entries).
	if (defined $checksecrets) {
		for my $line (split /\n/, $checksecrets) {
			next unless $line =~ /^\s*(secret\/\S+):(\S+)\s+provided\s*$/;
			my ($path, $key) = ($1, $2);
			# Stub value; content doesn't matter, only presence.
			_run_cmd(['safe', 'set', $path, "$key=stub"], stderr => '&1');
		}
	}

	# add-secrets generates every non-provided secret.
	_run_cmd(
		Kit::Validator::Runner::Cmd::genesis_add_secrets_cmd(env => $env),
		onfailure => "genesis add-secrets failed for ".$env->name,
	);

	# Export everything under secret/<env-with-slashes>/<kit>/ and
	# tokenize the leaves to `<!{meta.vault}/<sub>:<key>!>`.
	my $vault_base = Kit::Validator::Bootstrap::env_vault_base(
		$env->name, $kit_name);
	my $export_json = _run_cmd(
		['safe', 'export', $vault_base],
		stderr => '&1',
	);
	# safe export emits JSON keyed by full vault path with {key=>value}
	# leaves.  Empty on no matches.
	require Genesis;
	my $export = Genesis::load_json($export_json // '{}');
	$export = {} unless ref($export) eq 'HASH';
	my $tokenized = Kit::Validator::Bootstrap::tokenize_vault_export(
		$export,
		env_name => $env->name,
		kit_name => $kit_name,
	);
	# Write to spec/vault/<env>.yml via Genesis::to_yaml (which shells
	# through spruce for consistent output).
	my $body = Genesis::to_yaml($tokenized);
	$fx->write('vault', $env->name, $body);
}

sub _import_vault_cache {
	my ($fx, $env, $vault) = @_;
	return unless $fx->exists('vault', $env->name);
	# safe import reads JSON from stdin; our spec/vault/<env>.yml is
	# YAML.  Roundtrip via load_yaml + JSON::PP to feed safe.
	require Genesis;
	require JSON::PP;
	my $data = Genesis::load_yaml_file($fx->path('vault', $env->name)) || {};
	my $json = JSON::PP->new->allow_nonref->encode($data);
	_run_cmd(['safe', 'import'], stderr => '&1', stdin => $json);
}

sub _run_genesis_step {
	my (%o) = @_;
	my $cmd       = $o{cmd}       or die "_run_genesis_step: cmd required\n";
	my $step_name = $o{step_name} or die "_run_genesis_step: step_name required\n";
	my $matcher   = $o{matcher};
	my $capture   = $o{capture};

	# Route through _run_cmd for HOME/dir plumbing.  Capture stdout
	# and stderr separately -- stderr => 0 tells Genesis::run to
	# collect stderr into a scratch file and return it as the third
	# tuple element in list context.  This matters for genesis
	# manifest, whose stdout IS the YAML we want to feed to Prune;
	# merging stderr would corrupt the manifest with progress
	# banners like `[env/kit] determining manifest fragments...`.
	my ($out, $rc, $err) = _run_cmd($cmd, stderr => 0);
	$out //= '';
	$err //= '';
	my $combined = $out . ($err ? "\n$err" : '');

	if ($matcher) {
		# output_matchers case: env expects the subcommand to fail (or
		# succeed) with a specific message.  Regex-match the combined
		# stream; non-zero rc is tolerated when the matcher fires.
		if ($combined =~ $matcher) {
			# Pattern matched -- this env's assertion is satisfied at
			# the CLI-output layer, not at the manifest-diff layer.
			# Return undef so the caller short-circuits the remainder
			# of the pipeline (prune/interpolate/diff).
			return;
		}
		die "$step_name: output_matcher did not match.\n".
		    "Pattern: $matcher\n".
		    "Output:\n$combined\n";
	}

	# No matcher: expect a clean exit.
	if ($rc) {
		die "$step_name failed (rc=$rc):\n$combined\n";
	}
	# Capture returns stdout only -- callers that want the manifest
	# YAML need it uncontaminated by progress banners.
	return $capture ? $out : undef;
}

sub _env_has_proto_feature {
	my ($env, $workdir) = @_;
	# The env yml has already been copied into $workdir/deployments/
	# by _copy_env_fixture (step 6); read it back to decide whether
	# to preserve create-env-shaped top-level keys during Prune.
	require Genesis;
	my $path = "$workdir/deployments/".$env->name.".yml";
	return 0 unless -f $path;
	my $spec = eval { Genesis::load_yaml_file($path) };
	return 0 unless ref($spec) eq 'HASH';
	my $features = $spec->{kit}{features} // [];
	return 0 unless ref($features) eq 'ARRAY';
	return (grep { defined && $_ eq 'proto' } @$features) ? 1 : 0;
}

sub _bootstrap_credhub_stub_if_missing {
	my ($fx, $env, $manifest, $workdir) = @_;
	return if $fx->exists('credhub', $env->name);

	# Only fires when the manifest actually declares credhub-style
	# variables.  Skip cleanly when the block is empty or absent so
	# we don't leave dead git noise around for envs that don't use
	# credhub at all.
	my $vars = $manifest->{variables};
	return unless ref($vars) eq 'ARRAY' && @$vars;

	# Write the *pruned* manifest to a scratch file.  Matching testkit:
	# any variable that references a pruned top-level (meta, params,
	# pipeline, ...) legitimately fails here, which is the framework
	# surfacing "this env is coupling to something a real deploy
	# wouldn't have" -- a bug worth catching.
	require Genesis;
	my $mpath = "$workdir/kv-credhub-manifest.yml";
	open my $fh, '>', $mpath or die "cannot write $mpath: $!";
	print $fh Genesis::to_yaml($manifest);
	close $fh;

	# Ask bosh to generate values into a fresh vars-store.  This is
	# purely client-side: bosh walks the variables: block and
	# synthesizes certs/passwords locally.  No director contact.
	my $store_path = "$workdir/kv-credhub-store.yml";
	_run_cmd(
		['bosh', 'int', $mpath, '--vars-store', $store_path],
		stderr => 0,
		onfailure => "bosh int --vars-store failed while bootstrapping "
			.$env->name."'s credhub stub",
	);

	# Read the generated store and tokenize each variable.  Scalars
	# become <!{credhub}:<var>!>; hash-shaped variables (typical for
	# certificates: {ca, certificate, private_key}) expand to
	# <!{credhub}:<var>.<subkey>!> per subkey.  Bootstrap has this.
	my $store = Genesis::load_yaml_file($store_path) || {};
	return unless ref($store) eq 'HASH' && keys %$store;
	my $tokenized = Kit::Validator::Bootstrap::tokenize_credhub_vars($store);
	$fx->write('credhub', $env->name, Genesis::to_yaml($tokenized));
}

sub _interpolate {
	my ($fx, $env, $manifest, $bosh_vars, $workdir) = @_;

	# Write $manifest and $bosh_vars to scratch files, then shell to
	# `bosh int` with --vars-file each of them plus any credhub bits.
	# Returns the rendered YAML text.
	require Genesis;
	my $manifest_yaml = Genesis::to_yaml($manifest);
	my $vars_yaml     = Genesis::to_yaml($bosh_vars // {});

	my $mpath = "$workdir/kv-manifest.yml";
	my $vpath = "$workdir/kv-bosh-vars.yml";
	open my $mfh, '>', $mpath or die "cannot write $mpath: $!";
	print $mfh $manifest_yaml;
	close $mfh;
	open my $vfh, '>', $vpath or die "cannot write $vpath: $!";
	print $vfh $vars_yaml;
	close $vfh;

	# Optional credhub_variables (per-env literal overrides) and the
	# credhub stub (tokenized).  Both are threaded into `bosh int` as
	# additional --vars-file entries in the same order testkit uses.
	my (@credhub_vars, @credhub_stub);
	if (my $cv = $env->credhub_vars) {
		if ($fx->exists('credhub_variables', $cv)) {
			@credhub_vars = ($fx->path('credhub_variables', $cv));
		}
	}
	if ($fx->exists('credhub', $env->name)) {
		@credhub_stub = ($fx->path('credhub', $env->name));
	}

	my $cmd = Kit::Validator::Runner::Cmd::bosh_int_cmd(
		manifest_path      => $mpath,
		bosh_vars_path     => $vpath,
		credhub_vars_path  => $credhub_vars[0],
		credhub_stub_path  => $credhub_stub[0],
	);
	my ($out, $rc, $err) = _run_cmd($cmd, stderr => 0);
	if ($rc) {
		die "bosh int failed (rc=$rc):\n$out\n$err\n";
	}
	return $out;
}

sub _compare_or_bootstrap_golden {
	my ($fx, $env, $rendered) = @_;
	if (!$fx->exists('results', $env->name)) {
		# First run: materialize the golden and pass silently.
		# Parity with testkit's createResultIfMissingForManifest.
		$fx->write('results', $env->name, $rendered);
		return;
	}

	# Write the rendered manifest to a temp path so spruce diff can
	# see it as a file (spruce reads from paths, not stdin).
	require File::Temp;
	my ($fh, $actual) = File::Temp::tempfile(
		'kv-actual-XXXXXX', SUFFIX => '.yml',
		DIR => File::Spec->tmpdir, UNLINK => 1,
	);
	print $fh $rendered;
	close $fh;

	my $golden = $fx->path('results', $env->name);
	my ($out, $rc, $err) = _run_cmd(
		Kit::Validator::Runner::Cmd::spruce_diff_cmd(
			golden_path => $golden,
			actual_path => $actual,
		),
		stderr => 0,
	);
	# spruce diff exit codes:
	#   0 = no changes
	#   1 = differences (real diff to report)
	#   >1 = tool error (bad YAML, missing file, etc.)
	return if ($rc // 0) == 0;

	# Strip ANSI when the test harness isn't a TTY -- CI logs already
	# stripped, but `prove` locally can be either.
	my $diff = defined($out) ? $out : '';
	$diff .= "\n$err" if $err;
	unless (-t STDOUT) {
		$diff =~ s/\e\[[0-9;]*m//g;
	}
	die "manifest differs from spec/results/".$env->name.".yml:\n$diff\n";
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
