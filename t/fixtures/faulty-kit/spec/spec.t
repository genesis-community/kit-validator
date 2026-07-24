#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

# Load the framework from the parent kit-validator checkout.
use lib "$FindBin::Bin/../../../../lib";

use Genesis::Kit::Validator::Spec qw/kit_dir test_env/;
use Test::More;

kit_dir("$FindBin::Bin/..");

# Every env here is an expected failure.  The output_matcher IS the
# assertion: the Runner skips vault bootstrap and golden-manifest
# comparison for these, and fails the subtest if Genesis's output
# does not match.
#
# Keep one env per error path so a regression names itself.

# A spruce operator inside a go-patch `value:` block survives the merge
# and reaches instance_groups.*.azs, where Genesis bails rather than
# filtering it away.  Reached via `genesis check` -> _check_cpis ->
# cpi_az_map -> instance_group_azs, which is why faulty-kit must not
# declare `services: [director]` (create-env envs skip that check).
test_env(
	name            => 'gopatch-azs-marker',
	cloud_config    => 'test',
	check_cpis      => 1,
	output_matchers => {
		genesis_check => qr/unresolved spruce operator/i,
	},
);

done_testing;
