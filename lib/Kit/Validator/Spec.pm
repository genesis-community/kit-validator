package Kit::Validator::Spec;
use v5.20;
use warnings;

use Exporter ();
use File::Temp ();
use File::Spec ();

use Kit::Validator qw/kit_dir test_env/;

our @ISA       = ('Exporter');
our @EXPORT_OK = qw/kit_dir test_env/;

# One-shot sandbox state.
my $INITIALIZED;
our $SANDBOX_HOME;
my $_sandbox_guard;

# import - the spec.t entry point.  Every generalizable per-run setup
# task (HOME sandbox, git identity, ...) fires here, exactly once.
# Additional harness modules that layer on top of this (e.g. a future
# Kit::Validator::Hooks) can inherit or invoke the same setup.
sub import {
	my $class = shift;
	unless ($INITIALIZED) {
		$INITIALIZED = 1;
		_init_sandbox();
	}
	Exporter::export_to_level($class, 1, $class, @_);
}

# _init_sandbox - create a run-scoped $HOME so ~/.saferc, ~/.genesis,
# and every path resolved against HOME live inside this process's
# private tempdir instead of the developer's real home.  A lexical
# File::Temp::Dir keeps CLEANUP tied to interpreter exit; the caller's
# env (PERL5LIB, PATH, GENESIS_LIB, KIT_VALIDATOR_GENESIS, ...)
# is inherited untouched, so overrides and cpanm-installed modules
# continue to work.
sub _init_sandbox {
	$_sandbox_guard = File::Temp->newdir(
		'kv-XXXXXX', DIR => File::Spec->tmpdir, CLEANUP => 1,
	);
	$SANDBOX_HOME = $_sandbox_guard->dirname;

	$ENV{HOME}            = $SANDBOX_HOME;
	$ENV{XDG_CONFIG_HOME} = "$SANDBOX_HOME/.config";

	# Genesis's `genesis init` refuses to run without git identity
	# (Genesis::Commands::Repo, ~v3.x forward).  Provide one via env
	# vars rather than seeding a .gitconfig -- keeps the sandbox
	# filesystem free of test state, and env is inherited by every
	# child process automatically.
	$ENV{GIT_AUTHOR_NAME}     //= 'Kit Validator';
	$ENV{GIT_AUTHOR_EMAIL}    //= 'validator@localhost';
	$ENV{GIT_COMMITTER_NAME}  //= $ENV{GIT_AUTHOR_NAME};
	$ENV{GIT_COMMITTER_EMAIL} //= $ENV{GIT_AUTHOR_EMAIL};
}

1;

__END__

=head1 NAME

Kit::Validator::Spec - spec.t entrypoint that gates run-scoped sandbox setup

=head1 SYNOPSIS

  use Kit::Validator::Spec qw/kit_dir test_env/;

  kit_dir("$FindBin::Bin/..");

  test_env(name => 'aws', cloud_config => 'aws');
  test_env(name => 'proto-aws');

=head1 DESCRIPTION

C<Kit::Validator::Spec> is the module a kit's C<spec/spec.t> file
loads.  On first C<use> it rebases C<$ENV{HOME}> and
C<$ENV{XDG_CONFIG_HOME}> onto a fresh, auto-cleanup tempdir and seeds
a synthetic git identity via C<GIT_AUTHOR_NAME> / C<GIT_AUTHOR_EMAIL>.
Every C<test_env> call, every child process it forks off (bash hooks
included), inherits the same sandbox HOME -- so the local vault's
C<.saferc> entry, the C<.genesis> extract, and any path resolved via
C<~> stay coherent across the run and cannot bleed the developer's
real home into the test.

Internal Kit::Validator modules load C<Kit::Validator> directly; only
C<spec.t> files should load C<Kit::Validator::Spec>.  Sibling harness
modules (e.g. a future C<Kit::Validator::Hooks>) can layer their own
setup on top of this one.

The sandbox is a C<File::Temp-E<gt>newdir(CLEANUP =E<gt> 1)> and is
removed on interpreter exit.

=head1 REQUIRED RUNTIME

C<Kit::Validator> is expected to be discoverable on C<@INC> -- typical
install is C<cpanm .> from a checkout, which puts it under a directory
already on the user's C<PERL5LIB>.

C<genesis> is expected to be on C<$PATH>.  For dev iteration against a
source checkout, set C<GENESIS_LIB> to that checkout's C<lib/> and
C<KIT_VALIDATOR_GENESIS> to its C<bin/genesis>; both are honored as
overrides by C<Kit::Validator::Runner>.

=head1 EXPORTED

Re-exports C<kit_dir> and C<test_env> from C<Kit::Validator>.

=cut
