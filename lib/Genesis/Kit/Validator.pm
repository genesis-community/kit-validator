package Genesis::Kit::Validator;
use v5.20;
use warnings;

our $VERSION = '0.2.0';

use Exporter 'import';
our @EXPORT_OK = qw/kit_dir test_env/;

our $KIT_DIR;
our @ENVIRONMENTS;

sub kit_dir {
	my ($dir) = @_;
	die "kit_dir(): directory not readable: $dir\n"
		unless defined $dir && -d $dir;
	require Cwd;
	$KIT_DIR = Cwd::abs_path($dir);

	# Expand any `@last-failed` sentinel in KIT_VALIDATOR_FOCUS
	# BEFORE we truncate the state file below -- otherwise the
	# retry list evaporates in the same call that would consume it.
	_expand_focus_last_failed();

	# Start every run with a clean failure log; the Runner
	# appends to it as envs fail, and the next `@last-failed`
	# resolution reads it back.
	_reset_last_failed();

	# Emit the runtime preamble now that we can resolve the kit name
	# from its kit.yml -- Spec::import fires before kit_dir() is
	# called, so the preamble is deferred here to include the name.
	require Genesis::Kit::Validator::Spec;
	Genesis::Kit::Validator::Spec::emit_preamble(_detect_kit_name($KIT_DIR));

	return $KIT_DIR;
}

# last_failed_path - kit-scoped path to the newline-delimited log
# of envs that failed on the last run.  Lives under spec/ so it
# travels with the kit's other test artifacts (results/, vault/,
# credhub/) but is not intended to be committed.
sub last_failed_path {
	return "$KIT_DIR/spec/.last-failed";
}

# _expand_focus_last_failed - if KIT_VALIDATOR_FOCUS is set to the
# sentinel `@last-failed`, replace it with the colon-joined names
# from the state file so downstream focus filtering works
# unchanged.  Prints a diagnostic on stderr so the operator sees
# what expanded.  A missing or empty state file falls back to
# running the full sweep -- signalled by clearing the env var.
sub _expand_focus_last_failed {
	my $focus = $ENV{KIT_VALIDATOR_FOCUS};
	return unless defined $focus && $focus eq '@last-failed';
	my $file = last_failed_path();
	unless (-f $file) {
		warn "KIT_VALIDATOR_FOCUS=\@last-failed: no state file at $file; running all envs\n";
		delete $ENV{KIT_VALIDATOR_FOCUS};
		return;
	}
	open my $fh, '<', $file or do {
		warn "KIT_VALIDATOR_FOCUS=\@last-failed: cannot read $file: $!; running all envs\n";
		delete $ENV{KIT_VALIDATOR_FOCUS};
		return;
	};
	my @names;
	while (my $line = <$fh>) {
		chomp $line;
		push @names, $line if length $line;
	}
	close $fh;
	if (@names) {
		$ENV{KIT_VALIDATOR_FOCUS} = join(':', @names);
		warn "KIT_VALIDATOR_FOCUS=\@last-failed -> retrying "
			.scalar(@names)." env(s): ".join(', ', @names)."\n";
	} else {
		delete $ENV{KIT_VALIDATOR_FOCUS};
		warn "KIT_VALIDATOR_FOCUS=\@last-failed: state file is empty; running all envs\n";
	}
}

# _reset_last_failed - truncate the state file at run start so the
# fresh set of failures is recorded cleanly.  Unlink if truncation
# fails (e.g. read-only), which still gives Runner a clean slate.
sub _reset_last_failed {
	my $file = last_failed_path();
	return unless -e $file;
	if (open my $fh, '>', $file) {
		close $fh;
	} else {
		unlink $file;
	}
}

# record_failure - Runner->run calls this from its fail branch to
# append an env name to the state file.  Idempotent per env
# because Runner emits at most one call per env's subtest.
sub record_failure {
	my ($name) = @_;
	return unless defined $KIT_DIR && defined $name;
	my $file = last_failed_path();
	if (open(my $fh, '>>', $file)) {
		print $fh "$name\n";
		close $fh;
	}
}

sub _detect_kit_name {
	my ($dir) = @_;
	my $kit_yml = "$dir/kit.yml";
	return undef unless -f $kit_yml;
	require Genesis;
	my $kit = eval { Genesis::load_yaml_file($kit_yml) } or return undef;
	return $kit->{name};
}

sub test_env {
	require Genesis::Kit::Validator::Environment;
	require Genesis::Kit::Validator::Runner;
	my $env = Genesis::Kit::Validator::Environment->new(@_);
	push @ENVIRONMENTS, $env;

	# KIT_VALIDATOR_FOCUS is a colon-separated allowlist of env names.
	# When set, only matching envs run; the rest silently skip.  Mirrors
	# Ginkgo's --focus (and the Environment.focus flag when set inline).
	if (my $focus = $ENV{KIT_VALIDATOR_FOCUS}) {
		my %allow = map { $_ => 1 } split /:/, $focus;
		return $env unless $allow{$env->name};
	}

	Genesis::Kit::Validator::Runner->run($env, kit_dir => $KIT_DIR);
	return $env;
}

1;

__END__

=head1 NAME

Genesis::Kit::Validator - Perl spec-test framework for Genesis kits

=head1 SYNOPSIS

  use lib $ENV{KIT_VALIDATOR_LIB};
  use Genesis::Kit::Validator qw/kit_dir test_env/;

  kit_dir('.');
  test_env(name => 'aws',       cloud_config => 'aws');
  test_env(name => 'proto-aws', cloud_config => 'aws');

=head1 DESCRIPTION

Genesis::Kit::Validator replaces the Ginkgo/Go test harness that Genesis kits
have historically used (via C<github.com/genesis-community/testkit>).
It runs entirely in Perl, leveraging the C<Genesis::*> and C<Service::*>
libraries already available on kit CI images.

Each C<test_env> call runs one environment through the standard
Genesis manifest-generation pipeline and diffs the resulting manifest
against a golden file under C<spec/results/E<lt>nameE<gt>.yml>.

=head1 REQUIRED RUNTIME

Genesis's C<lib/> must be loadable (i.e. C<use Genesis;> and
C<use Service::Vault::Local;> must succeed).  On kit CI images this
is already the case.  For local development, C<PERL5LIB> should
include the Genesis checkout's C<lib/> directory.

=cut
