#!perl
use strict;
use warnings;
use Test::More;

use_ok 'Genesis::Kit::Validator::Runner';

# The yamls diff step captures `genesis <env> yamls` stdout (a list
# of "<kit>/<version>: <path>" lines with a trailing "     local:"
# line), normalizes the kit-version token so kit-version bumps don't
# generate spurious diffs, and diffs against a golden file.  Tests
# below pin the normalization and diff helpers as pure functions.

subtest '_normalize_yamls_output: kit-version tokens get sentinel' => sub {
	my $input = <<'EOS';
bosh/3.1.0: bosh-deployment/bosh.yml
bosh/3.1.0: overlay/base.yml
     local: rsat-bc-ops.yml
EOS
	my $out = Genesis::Kit::Validator::Runner::_normalize_yamls_output($input);
	is $out, <<'EOS', 'each "bosh/3.1.0:" gets rewritten to "bosh/<VERSION>:"';
bosh/<VERSION>: bosh-deployment/bosh.yml
bosh/<VERSION>: overlay/base.yml
     local: rsat-bc-ops.yml
EOS
};

subtest '_normalize_yamls_output: dev/rc/build suffixes' => sub {
	my $input = <<'EOS';
bosh/3.2.999-dev: bosh-deployment/bosh.yml
bosh/3.2.0-rc.1: overlay/base.yml
bosh/3.2.0+build.abc: overlay/upstream_version.yml
     local: rsat-bc-ops.yml
EOS
	my $out = Genesis::Kit::Validator::Runner::_normalize_yamls_output($input);
	is $out, <<'EOS', 'loose regex matches any non-colon version suffix';
bosh/<VERSION>: bosh-deployment/bosh.yml
bosh/<VERSION>: overlay/base.yml
bosh/<VERSION>: overlay/upstream_version.yml
     local: rsat-bc-ops.yml
EOS
};

subtest '_normalize_yamls_output: local line and kit-name preserved' => sub {
	my $input = <<'EOS';
cf/2.5.1: cf-deployment/cf-deployment.yml
     local: aws.yml
EOS
	my $out = Genesis::Kit::Validator::Runner::_normalize_yamls_output($input);
	is $out, <<'EOS', 'kit name (cf) and local prefix pass through verbatim';
cf/<VERSION>: cf-deployment/cf-deployment.yml
     local: aws.yml
EOS
};

subtest '_normalize_yamls_output: strips ANSI color escapes' => sub {
	my $input = "\e[38;5;10mtiny/3.2.0:\e[0m \e[38;5;8mmanifests/tiny.yml\e[0m\n"
	          . "           \e[38;5;14mlocal:\e[0m minimal.yml\n";
	my $out = Genesis::Kit::Validator::Runner::_normalize_yamls_output($input);
	is $out,
		"tiny/<VERSION>: manifests/tiny.yml\n"
		. "           local: minimal.yml\n",
		'ANSI escapes stripped before version normalization';
};

subtest '_normalize_yamls_output: no double-rewrite if already normalized' => sub {
	my $input = <<'EOS';
bosh/<VERSION>: bosh-deployment/bosh.yml
     local: aws.yml
EOS
	my $out = Genesis::Kit::Validator::Runner::_normalize_yamls_output($input);
	is $out, $input, 'already-sentinel input is a no-op';
};

subtest '_diff_yamls: identical input returns empty string' => sub {
	my $t = "bosh/<VERSION>: a\n     local: b\n";
	is Genesis::Kit::Validator::Runner::_diff_yamls($t, $t), '',
		'no diff when actual == expected';
};

subtest '_diff_yamls: added line surfaces in diff' => sub {
	my $expected = "bosh/<VERSION>: a\n     local: b\n";
	my $actual   = "bosh/<VERSION>: a\nbosh/<VERSION>: new\n     local: b\n";
	my $d = Genesis::Kit::Validator::Runner::_diff_yamls($actual, $expected);
	like $d, qr/^\+bosh.*new/m, 'unified-diff format shows the added line';
	like $d, qr/^---/m, 'header present';
	like $d, qr/^\+\+\+/m, 'header present';
};

subtest '_diff_yamls: reordered lines surface as remove/add pair' => sub {
	my $expected = "bosh/<VERSION>: a\nbosh/<VERSION>: b\n     local: z\n";
	my $actual   = "bosh/<VERSION>: b\nbosh/<VERSION>: a\n     local: z\n";
	my $d = Genesis::Kit::Validator::Runner::_diff_yamls($actual, $expected);
	isnt $d, '', 'reordering is a diff, not a no-op';
};

done_testing;
