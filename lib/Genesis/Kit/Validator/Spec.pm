package Genesis::Kit::Validator::Spec;
use v5.20;
use warnings;
use utf8;

use Exporter ();
use File::Temp ();
use File::Spec ();

use Genesis::Kit::Validator qw/kit_dir test_env/;

our @ISA       = ('Exporter');
our @EXPORT_OK = qw/kit_dir test_env/;

use constant MIN_GENESIS_VERSION => '3.2.0-rc.0';

# One-shot sandbox state.  INITIALIZED is `our` (not `my`) so external
# callers -- notably Kit::Validator::kit_dir -- can check whether
# import() actually ran the runtime bring-up (Genesis lib load, shared
# vault, theme).  Framework unit tests use `use_ok` on this module but
# monkey-patch Runner->run to a no-op; without a way to see that state
# they hit emit_preamble's `require Genesis` and crash on the empty
# sandbox.
our $INITIALIZED;
our $SANDBOX_HOME;
our $SHARED_VAULT;
my $_sandbox_guard;

# import - the spec.t entry point.  Every generalizable per-run setup
# task (HOME sandbox, git identity, ...) fires here, exactly once.
# Additional harness modules that layer on top of this (e.g. a future
# Genesis::Kit::Validator::Hooks) can inherit or invoke the same setup.
sub import {
	my $class = shift;
	unless ($INITIALIZED) {
		$INITIALIZED = 1;
		_init_sandbox();
		require Genesis::Kit::Validator::Runner;
		Genesis::Kit::Validator::Runner::_require_genesis();
		_check_genesis_version();
		_start_shared_vault();
		_init_theme();
	}
	Exporter::export_to_level($class, 1, $class, @_);
}

# Theme palette: role -> Genesis::Term color letter.  Two variants
# swap in based on the detected terminal background so every role
# stays contrasty against whatever the operator's colour scheme is.
# `label` / `path` / `ident` land on cyan in both themes because
# dark cyan is legible on light AND dark backgrounds; roles that
# rely on brightness (accent / value / keyword / number / muted)
# flip case.
our %THEME;
my %_THEME_DARK = (
	accent  => 'B',   # section rules / preamble title (avoid G/R -- test verdict colours)
	label   => 'c',   # left-column field names
	value   => 'W',   # right-column field values
	keyword => 'Y',   # command names / verbs
	ident   => 'C',   # env names, identifiers
	path    => 'c',   # filesystem/vault paths
	number  => 'M',   # counts, indexes
	muted   => 'K',   # brackets, subtle chrome
);
my %_THEME_LIGHT = (
	accent  => 'b',
	label   => 'c',
	value   => 'k',
	keyword => 'y',
	ident   => 'c',
	path    => 'c',
	number  => 'm',
	muted   => 'k',
);
sub _init_theme {
	require Genesis::Term;
	my $tc = Genesis::Term::terminal_colors();
	%THEME = $tc && !$tc->{is_dark} ? %_THEME_LIGHT : %_THEME_DARK;
}

# theme_color - fetch the csprintf letter (e.g. 'Y') registered for
# a semantic role in the current theme.  Returns undef for unknown
# roles; callers using cprintf get a diagnostic when that happens.
sub theme_color { $THEME{$_[0]} }

# cprintf - csprintf with theme-role tokens.  Pre-processes markers
# of the form `#<role>{...}` (accent/label/value/keyword/ident/path/
# number/muted) into the letter registered for the current theme,
# then delegates to Genesis::Term::csprintf.  Regular one-letter
# csprintf markers (`#Y{...}` etc.) pass through untouched.
sub cprintf {
	my ($fmt, @args) = @_;
	# Delimit with `!` -- the default `{}` form counts braces on
	# both sides and would trip over the literal `{` we insert
	# into the replacement string.
	$fmt =~ s!#(accent|label|value|keyword|ident|path|number|muted)\{!'#' . ($THEME{$1} // 'W') . '{'!ge;
	require Genesis::Term;
	return Genesis::Term::csprintf($fmt, @args);
}

# emit_preamble - one-shot summary of the runtime context (which
# genesis, which libs, which focus filter, sandbox HOME, shared vault
# URL).  Written to STDERR via warn so it interleaves with the same
# stream as _step() progress lines and Test::More diag output.  Lets
# the operator see immediately whether the run is picking up the
# expected binary/lib and (crucially) whether KIT_VALIDATOR_FOCUS is
# scoping the sweep.  Called from Kit::Validator::kit_dir once the
# kit name can be resolved from $KIT_DIR/kit.yml.
sub emit_preamble {
	my ($kit_name) = @_;
	require Genesis;
	require Genesis::Term;
	my $binary = $ENV{KIT_VALIDATOR_GENESIS} || 'genesis';
	my $version = $Genesis::VERSION // '(development)';
	my $genesis_lib = $ENV{GENESIS_LIB} // '(default)';
	my $validator_lib = $ENV{KIT_VALIDATOR_LIB} // '(from @INC)';
	my $focus = $ENV{KIT_VALIDATOR_FOCUS};
	my $vault_url = eval { $SHARED_VAULT->url } // '(unknown)';
	my $title_text = defined $kit_name && length $kit_name
		? "Validating kit '$kit_name'"
		: "Validating kit";

	my $w = Genesis::Term::terminal_width();
	my $line = '═' x $w;
	my $row = sub {
		my ($label, $value) = @_;
		return cprintf("  #label{%-15s} : #value{%s}\n", $label, $value);
	};

	my $out = "\n\n"
		. cprintf("#accent{%s}\n", $line)
		. cprintf("  #accent{%s}\n", $title_text)
		. cprintf("#accent{%s}\n", $line)
		. $row->('genesis binary',  "$binary ($version)")
		. $row->('genesis lib',     $genesis_lib)
		. $row->('validator lib',   $validator_lib)
		. $row->('sandbox HOME',    $SANDBOX_HOME)
		. $row->('shared vault',    $vault_url)
		. ((defined $focus && length $focus) ? $row->('focus filter', $focus) : '')
		. cprintf("#accent{%s}\n", $line);
	warn $out;
}

# shared_vault - accessor for the run-scoped vault created in
# _start_shared_vault.  Returns undef if called before import().
sub shared_vault { $SHARED_VAULT }


# _start_shared_vault - one memory-backed vault for the whole spec.t
# run.  Every env's Runner->_execute writes into its own
# secret/<env-name>/<kit>/... subtree, so there's no cross-env
# contention on a shared store.  Avoids per-env vault start/stop cost
# and the safe(1) target/saferc restore dance between envs.
sub _start_shared_vault {
	require Service::Vault::Local;
	$SHARED_VAULT = Service::Vault::Local->create('kv-shared-'.$$);
}

# Tear the shared vault down at interpreter exit.  Runs before the
# sandbox HOME cleanup (File::Temp CLEANUP fires from the same END
# phase in reverse-declaration order), so `safe` still has a live
# .saferc to hit when shutdown reads its own target.
#
# Preserve $? across shutdown: Local::shutdown does kill+waitpid
# loops on the vault/safe child processes, and the waitpid side
# effect updates $?.  Test::Builder's END inspects $? after every
# user-space END has run and reports "your test exited with N"
# when it finds a stale non-zero -- turning an otherwise-clean
# `prove` run into a failing one.  Save-and-restore so the vault
# teardown stays semantically invisible to the test framework.
END {
	if ($SHARED_VAULT) {
		my $saved = $?;
		eval { $SHARED_VAULT->shutdown };
		$? = $saved;
	}
}

sub _check_genesis_version {
	require Genesis;
	my $have = $Genesis::VERSION // '';
	# "(development)" is the source-checkout sentinel; no semver to compare.
	return if $have eq '(development)' || $have eq '';
	return if Genesis::new_enough($have, MIN_GENESIS_VERSION);
	die
		"Genesis::Kit::Validator::Spec: loaded Genesis $have is older than the\n".
		"required floor ".MIN_GENESIS_VERSION.".  Kit-validator's assertions\n".
		"depend on exodus-template fields that older Genesis doesn't emit.\n".
		"\n".
		"Point KIT_VALIDATOR_GENESIS (and/or GENESIS_LIB) at a newer\n".
		"genesis binary + source checkout, or upgrade the genesis on \$PATH.\n";
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

Genesis::Kit::Validator::Spec - spec.t entrypoint that gates run-scoped sandbox setup

=head1 SYNOPSIS

  use Genesis::Kit::Validator::Spec qw/kit_dir test_env/;

  kit_dir("$FindBin::Bin/..");

  test_env(name => 'aws', cloud_config => 'aws');
  test_env(name => 'proto-aws');

=head1 DESCRIPTION

C<Genesis::Kit::Validator::Spec> is the module a kit's C<spec/spec.t> file
loads.  On first C<use> it rebases C<$ENV{HOME}> and
C<$ENV{XDG_CONFIG_HOME}> onto a fresh, auto-cleanup tempdir and seeds
a synthetic git identity via C<GIT_AUTHOR_NAME> / C<GIT_AUTHOR_EMAIL>.
Every C<test_env> call, every child process it forks off (bash hooks
included), inherits the same sandbox HOME -- so the local vault's
C<.saferc> entry, the C<.genesis> extract, and any path resolved via
C<~> stay coherent across the run and cannot bleed the developer's
real home into the test.

Internal Genesis::Kit::Validator modules load C<Genesis::Kit::Validator> directly; only
C<spec.t> files should load C<Genesis::Kit::Validator::Spec>.  Sibling harness
modules (e.g. a future C<Genesis::Kit::Validator::Hooks>) can layer their own
setup on top of this one.

The sandbox is a C<File::Temp-E<gt>newdir(CLEANUP =E<gt> 1)> and is
removed on interpreter exit.

=head1 REQUIRED RUNTIME

C<Genesis::Kit::Validator> is expected to be discoverable on C<@INC> -- typical
install is C<cpanm .> from a checkout, which puts it under a directory
already on the user's C<PERL5LIB>.

C<genesis> is expected to be on C<$PATH>.  For dev iteration against a
source checkout, set C<GENESIS_LIB> to that checkout's C<lib/> and
C<KIT_VALIDATOR_GENESIS> to its C<bin/genesis>; both are honored as
overrides by C<Genesis::Kit::Validator::Runner>.

=head1 EXPORTED

Re-exports C<kit_dir> and C<test_env> from C<Genesis::Kit::Validator>.

=cut
