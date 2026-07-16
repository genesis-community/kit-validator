package Genesis::Kit::Validator::Prune;
use v5.20;
use warnings;
use Storable qw/dclone/;

# Keys stripped in every prune.
our @TOP_LEVEL_DROPS = qw/
	meta
	pipeline
	params
	kit
	genesis
	compilation
/;

# Keys stripped only when the env does NOT declare the `proto` feature.
# In proto (BOSH create-env) mode, the manifest legitimately owns these
# fields; in director-managed mode, they come from cloud-config and
# would just cause diff noise.
our @NON_PROTO_DROPS = qw/
	resource_pools
	vm_types
	disk_pools
	disk_types
	networks
	azs
	vm_extensions
/;

# Subkeys stripped under `exodus:`.  Volatile bookkeeping that the
# kit records for post-deploy visibility, but never a stable target
# for spec assertions.  `upgarding` is misspelled in Genesis (yes,
# really); carried forward for parity with the Go testkit.
our @EXODUS_DROPS = qw/
	version
	dated
	deployer
	kit_name
	kit_version
	vault_base
	kit_is_dev
	upgarding
/;

sub prune_manifest {
	my ($manifest, $opts) = @_;
	$opts //= {};
	my $is_proto = $opts->{is_proto} ? 1 : 0;

	my $pruned = dclone($manifest);

	# Peel off bosh-variables for the runner (bosh int --vars-file).
	my $bosh_vars = delete($pruned->{'bosh-variables'}) // {};

	delete $pruned->{$_} for @TOP_LEVEL_DROPS;
	delete $pruned->{$_} for $is_proto ? () : @NON_PROTO_DROPS;

	if (ref $pruned->{exodus} eq 'HASH') {
		delete $pruned->{exodus}{$_} for @EXODUS_DROPS;
	}

	return ($pruned, $bosh_vars);
}

1;

__END__

=head1 NAME

Genesis::Kit::Validator::Prune - Strip volatile keys from a manifest before diff

=head1 SYNOPSIS

  use Genesis::Kit::Validator::Prune;
  my ($pruned, $bosh_vars) = Genesis::Kit::Validator::Prune::prune_manifest(
      $manifest, {is_proto => 0}
  );

=head1 FUNCTIONS

=head2 prune_manifest($manifest, \%opts)

Pure function.  Returns a two-element list: (a) a deep-cloned copy of
the manifest with volatile keys removed; (b) the C<bosh-variables:>
block (or an empty hashref) peeled off separately, so the runner can
feed it to C<bosh int --vars-file> during interpolation.

Options:

=over 4

=item * C<is_proto> -- when true, retains network-shape top-level keys
(C<resource_pools>, C<vm_types>, etc.) that a BOSH create-env manifest
legitimately owns.  Default false.

=back

=cut
