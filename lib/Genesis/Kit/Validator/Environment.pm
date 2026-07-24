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
		# `genesis check` forces its cpis option off when unset (see
		# Genesis::Commands::Env), so the CPI availability check --
		# and with it cpi_az_map / instance_group_azs -- never runs
		# unless asked for.  Opt-in per env rather than on by
		# default: enabling it globally would make every existing kit
		# suite start resolving AZs against its cloud-config, a
		# behaviour change those suites did not ask for.
		check_cpis      => $opts{check_cpis} ? 1 : 0,
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
sub check_cpis      { $_[0]{check_cpis} }
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

=item * C<check_cpis> -- boolean; adds C<--cpis> to C<genesis check>.
Off by default, matching Genesis: C<genesis check> forces its C<cpis>
option to 0 when unset, so the CPI availability check does not run
unless asked.  That check is the only route from C<genesis check> to
C<Genesis::Env::cpi_az_map> and C<instance_group_azs>, so an env
asserting on AZ or CPI resolution B<must> set this or it will pass
without ever exercising the code it targets.

Note the check is also skipped for create-env environments, so a kit
declaring C<services: [director]> cannot reach it regardless of this
flag.

=item * C<output_matchers> -- hashref of C<genesis_{check,add_secrets,manifest}>
keys to Regexp values.  When set, the corresponding subcommand's
combined stdout+stderr must match the regex (and non-zero exit is
tolerated).

Setting C<genesis_check> also ends the pipeline once the check has been
matched: an environment whose preflight fails never legitimately
reaches manifest generation, so no golden manifest is produced for it.

=back

=head1 LIMITATIONS

C<output_matchers> asserts on output, not on exit status -- a matcher
fires whether the subcommand exited zero or non-zero.  An env whose
command unexpectedly starts succeeding while still printing matching
text would continue to pass.  Write matchers specific enough that only
the failure path can produce them.

=cut
