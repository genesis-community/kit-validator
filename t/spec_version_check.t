#!perl
use strict;
use warnings;
use Test::More;

# Kit::Validator::Spec's sandbox setup requires a Genesis lib >= a
# floor version, because kit-validator's Runner + goldens rely on
# exodus-template fields (iaas, scale, services, ...) that Genesis
# didn't emit until v3.2.0-rc.0.  Older Genesis produces a manifest
# missing those fields; the diff against a golden generated against
# a fresh Genesis is guaranteed to fail with a confusing dyff.  Bail
# fast with an actionable message instead.

use_ok 'Kit::Validator::Spec';

my $min = Kit::Validator::Spec::MIN_GENESIS_VERSION();
ok defined $min && length $min, 'MIN_GENESIS_VERSION is defined and non-empty';
is $min, '3.2.0-rc.0', 'floor is 3.2.0-rc.0 (3.1.0 never got a stable release)';

subtest '_check_genesis_version: too old bails with actionable message' => sub {
	local $Genesis::VERSION = '3.0.5';
	eval { Kit::Validator::Spec::_check_genesis_version() };
	my $err = $@;
	like $err, qr/Genesis.*3\.0\.5/,          'error names the offending version';
	like $err, qr/3\.2\.0-rc\.0/,             'error names the required floor';
	like $err, qr/GENESIS_LIB|KIT_VALIDATOR_GENESIS/i,
		'error hints at the env vars that steer discovery';
};

subtest '_check_genesis_version: exactly the floor passes' => sub {
	local $Genesis::VERSION = '3.2.0-rc.0';
	eval { Kit::Validator::Spec::_check_genesis_version() };
	is $@, '', 'exact floor version passes';
};

subtest '_check_genesis_version: newer stable passes' => sub {
	local $Genesis::VERSION = '3.2.5';
	eval { Kit::Validator::Spec::_check_genesis_version() };
	is $@, '', 'newer stable passes';
};

subtest '_check_genesis_version: (development) passes with a warn diag' => sub {
	# Dev iteration -- we can't parse "(development)" as semver, so
	# the check must not fail.  A trace/debug diag is nice-to-have.
	local $Genesis::VERSION = '(development)';
	eval { Kit::Validator::Spec::_check_genesis_version() };
	is $@, '', 'the "(development)" sentinel doesn\'t bail';
};

done_testing;
