package Kit::Validator;
use v5.20;
use warnings;

our $VERSION = '0.0.1';

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
	return $KIT_DIR;
}

sub test_env {
	require Kit::Validator::Environment;
	require Kit::Validator::Runner;
	my $env = Kit::Validator::Environment->new(@_);
	push @ENVIRONMENTS, $env;

	# KIT_VALIDATOR_FOCUS is a colon-separated allowlist of env names.
	# When set, only matching envs run; the rest silently skip.  Mirrors
	# Ginkgo's --focus (and the Environment.focus flag when set inline).
	if (my $focus = $ENV{KIT_VALIDATOR_FOCUS}) {
		my %allow = map { $_ => 1 } split /:/, $focus;
		return $env unless $allow{$env->name};
	}

	Kit::Validator::Runner->run($env, kit_dir => $KIT_DIR);
	return $env;
}

1;

__END__

=head1 NAME

Kit::Validator - Perl spec-test framework for Genesis kits

=head1 SYNOPSIS

  use lib $ENV{KIT_VALIDATOR_LIB};
  use Kit::Validator qw/kit_dir test_env/;

  kit_dir('.');
  test_env(name => 'aws',       cloud_config => 'aws');
  test_env(name => 'proto-aws', cloud_config => 'aws');

=head1 DESCRIPTION

Kit::Validator replaces the Ginkgo/Go test harness that Genesis kits
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
