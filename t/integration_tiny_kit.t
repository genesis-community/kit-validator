#!perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw/rmtree/;

# Integration test — drives the synthetic tiny-kit end-to-end.
#
# Requires real binaries on PATH: genesis, safe, bosh, spruce.  Also
# requires Genesis's Perl lib to be loadable (PERL5LIB pointing at
# a Genesis checkout's lib/).
#
# Gated by KIT_VALIDATOR_INTEGRATION=1 so unit-only CI runs stay fast
# and don't need the external dependencies.

unless ($ENV{KIT_VALIDATOR_INTEGRATION}) {
	plan skip_all => 'set KIT_VALIDATOR_INTEGRATION=1 to run the tiny-kit smoke';
}

for my $bin (qw/genesis safe bosh spruce/) {
	my $found = 0;
	for my $dir (split /:/, $ENV{PATH}) {
		if (-x "$dir/$bin") { $found = 1; last; }
	}
	plan skip_all => "required binary '$bin' not on PATH"
		unless $found;
}

my $kit_dir = "$FindBin::Bin/fixtures/tiny-kit";
ok -d $kit_dir, "tiny-kit fixture present at $kit_dir";
ok -f "$kit_dir/kit.yml",                  'kit.yml present';
ok -f "$kit_dir/hooks/blueprint.pm",       'blueprint hook present';
ok -f "$kit_dir/manifests/tiny.yml",       'manifest template present';
ok -f "$kit_dir/spec/spec.t",              'spec.t present';
ok -f "$kit_dir/spec/deployments/minimal.yml", 'minimal env fixture present';

# Clean any auto-materialized artefacts from a previous run so we
# exercise both bootstrap-then-compare paths.
for my $auto (qw/vault results credhub/) {
	rmtree "$kit_dir/spec/$auto" if -d "$kit_dir/spec/$auto";
}

# Run 1: cold start.  Framework should:
#   1. spin ephemeral vault
#   2. genesis init + add-secrets + export -> materialize spec/vault/minimal.yml
#   3. genesis manifest -> materialize spec/results/minimal.yml
#   4. subtest passes (first-run: golden is bootstrapped, not compared)
my $rc = system("prove '$kit_dir/spec/spec.t' >/dev/null 2>&1");
is $rc, 0, 'cold-start run: prove exits 0';
ok -f "$kit_dir/spec/vault/minimal.yml",   'vault stub was auto-materialized';
ok -f "$kit_dir/spec/results/minimal.yml", 'results golden was auto-materialized';

# Run 2: warm.  With both stubs present, framework should compare
# against golden and pass.
$rc = system("prove '$kit_dir/spec/spec.t' >/dev/null 2>&1");
is $rc, 0, 'warm-run: prove exits 0 (spruce diff clean)';

done_testing;
