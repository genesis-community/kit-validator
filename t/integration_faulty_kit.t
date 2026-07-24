#!perl
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Path qw/rmtree/;

# Integration test — drives the synthetic faulty-kit end-to-end.
#
# Where integration_tiny_kit.t proves the happy path works, this proves
# the expected-failure path works: that Genesis actually fails for each
# scenario, and that the Runner's output_matchers machinery notices.
# Without this, a regression that silently stopped surfacing errors
# would look exactly like a passing suite.
#
# Same external requirements and gating as the tiny-kit smoke.

unless ($ENV{KIT_VALIDATOR_INTEGRATION}) {
	plan skip_all => 'set KIT_VALIDATOR_INTEGRATION=1 to run the faulty-kit smoke';
}

for my $bin (qw/genesis safe bosh spruce/) {
	my $found = 0;
	for my $dir (split /:/, $ENV{PATH}) {
		if (-x "$dir/$bin") { $found = 1; last; }
	}
	plan skip_all => "required binary '$bin' not on PATH"
		unless $found;
}

my $kit_dir = "$FindBin::Bin/fixtures/faulty-kit";
ok -d $kit_dir, "faulty-kit fixture present at $kit_dir";
ok -f "$kit_dir/kit.yml",            'kit.yml present';
ok -f "$kit_dir/hooks/blueprint.pm", 'blueprint hook present';
ok -f "$kit_dir/manifests/base.yml", 'base manifest present';
ok -f "$kit_dir/spec/spec.t",        'spec.t present';

ok -f "$kit_dir/manifests/gopatch-azs-marker.yml",
	'gopatch-azs-marker fault manifest present';
ok -f "$kit_dir/spec/deployments/gopatch-azs-marker.yml",
	'gopatch-azs-marker env fixture present';

# faulty-kit must not become a director kit.  Genesis skips the CPI
# availability check for create-env environments, and that check is the
# only route from `genesis check` to instance_group_azs -- so declaring
# `services: [director]` would make the azs scenario silently stop
# testing anything while still passing.
my $kit_yml = do { local (@ARGV, $/) = ("$kit_dir/kit.yml"); <> };
unlike $kit_yml, qr/^\s*-\s*director\s*$/m,
	'faulty-kit does not declare the director service';

# Likewise, no credentials: envs with output_matchers skip vault
# bootstrap, so a declared credential would leave an unresolvable
# `(( vault ))` and fail the merge before the intended fault fires.
unlike $kit_yml, qr/^credentials:/m,
	'faulty-kit declares no credentials';

# Every scenario is an expected failure, so no golden manifest should
# ever be materialised.  A results/ file appearing here means the
# pipeline ran further than it should have.
rmtree "$kit_dir/spec/$_" for qw/vault results credhub/;

my $rc = system("prove '$kit_dir/spec/spec.t' >/dev/null 2>&1");
is $rc, 0, 'faulty-kit scenarios all fail as expected: prove exits 0';

ok !-e "$kit_dir/spec/results/gopatch-azs-marker.yml",
	'no golden manifest materialised for an expected-failure env';

# Re-run: expected-failure envs must be stable, not first-run-only.
$rc = system("prove '$kit_dir/spec/spec.t' >/dev/null 2>&1");
is $rc, 0, 'second run: still exits 0 (no bootstrap-once behaviour)';

done_testing;
