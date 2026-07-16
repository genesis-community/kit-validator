package Genesis::Kit::Validator::Environment;
use v5.20;
use warnings;

# Recognized keys in output_matchers.  Regex applied to the
# combined stdout+stderr of the named genesis subcommand.  When
# the env expects the subcommand to fail, its output must match
# the given pattern; otherwise a normal success assertion applies.
our %OUTPUT_MATCHER_KEYS = map { $_ => 1 } qw/
	genesis_check
	genesis_add_secrets
	genesis_manifest
/;

sub new {
	my ($class, %opts) = @_;

	my $name = $opts{name};
	die "Genesis::Kit::Validator::Environment: name is required\n"
		unless defined $name && length $name;
	# Semantic validation of the env name (character set, path-traversal
	# safety, etc.) happens in Genesis::Kit::Validator::Runner where Genesis::Env
	# is already loaded and its _env_name_errors is DRY-callable.

	my $ops = $opts{ops} // [];
	die "Genesis::Kit::Validator::Environment: ops must be an arrayref\n"
		unless ref $ops eq 'ARRAY';

	my $matchers = $opts{output_matchers} // {};
	die "Genesis::Kit::Validator::Environment: output_matchers must be a hashref\n"
		unless ref $matchers eq 'HASH';
	for my $k (keys %$matchers) {
		die "Genesis::Kit::Validator::Environment: unknown output_matcher: $k\n"
			unless $OUTPUT_MATCHER_KEYS{$k};
		die "Genesis::Kit::Validator::Environment: output_matcher $k must be a Regexp\n"
			unless ref $matchers->{$k} eq 'Regexp';
	}

	return bless {
		name            => $name,
		cloud_config    => $opts{cloud_config},
		runtime_config  => $opts{runtime_config},
		cpi_config      => $opts{cpi_config},
		credhub_vars    => $opts{credhub_vars},
		exodus          => $opts{exodus},
		cpi             => $opts{cpi} // '',
		ops             => $ops,
		focus           => $opts{focus} ? 1 : 0,
		output_matchers => $matchers,
	}, $class;
}

sub name            { $_[0]{name} }
sub cloud_config    { $_[0]{cloud_config} }
sub runtime_config  { $_[0]{runtime_config} }
sub cpi_config      { $_[0]{cpi_config} }
sub credhub_vars    { $_[0]{credhub_vars} }
sub exodus          { $_[0]{exodus} }
sub cpi             { $_[0]{cpi} }
sub ops             { $_[0]{ops} }
sub focus           { $_[0]{focus} }
sub output_matchers { $_[0]{output_matchers} }

1;

__END__

=head1 NAME

Genesis::Kit::Validator::Environment - Immutable spec of one test environment

=head1 SYNOPSIS

  my $env = Genesis::Kit::Validator::Environment->new(
    name           => 'aws',
    cloud_config   => 'aws',
    runtime_config => 'dns',
    ops            => [qw/test-ops-override/],
  );

=head1 FIELDS

=over 4

=item * C<name> (required) -- environment name; matches
C<spec/deployments/E<lt>nameE<gt>.yml>.

=item * C<cloud_config> -- resolves to C<spec/cloud_configs/E<lt>valueE<gt>.yml>.

=item * C<runtime_config> -- resolves to C<spec/runtime_configs/E<lt>valueE<gt>.yml>.

=item * C<cpi_config> -- resolves to C<spec/cpi_configs/E<lt>valueE<gt>.yml>.
When unset, the Runner supplies an empty stub (C<cpis: []>) to satisfy
Genesis's opportunistic CPI prefetch without a live director lookup.

=item * C<credhub_vars> -- resolves to C<spec/credhub_variables/E<lt>valueE<gt>.yml>.

=item * C<exodus> -- resolves to C<spec/exodus/E<lt>valueE<gt>.yml>; imported
into vault under C<secret/exodus/E<lt>nameE<gt>>.

=item * C<cpi> -- string passed as C<GENESIS_TESTING_BOSH_CPI> env var.

=item * C<ops> -- arrayref of ops-file basenames under C<spec/ops/>.

=item * C<focus> -- boolean; when true, only focused envs run (Ginkgo
C<FIt> equivalent).

=item * C<output_matchers> -- hashref of C<genesis_{check,add_secrets,manifest}>
keys to Regexp values.  When set, the corresponding subcommand's
combined stdout+stderr must match the regex (and non-zero exit is
tolerated).

=back

=cut
