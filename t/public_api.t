#!perl
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

# Public API contract: what a kit's spec/spec.t imports and calls.
#
# The Runner's ->run is monkey-patched to a no-op recorder so we can
# assert the API forwards the right arguments without dragging in the
# Genesis runtime.

use_ok 'Genesis::Kit::Validator';
use_ok 'Genesis::Kit::Validator::Runner';   # load before monkey-patching ::run

my $kit = tempdir(CLEANUP => 1);
make_path("$kit/spec");

my @collected;
{
	no warnings qw/redefine once/;
	*Genesis::Kit::Validator::Runner::run = sub {
		my ($class, $env, %opts) = @_;
		push @collected, {env => $env, opts => \%opts};
	};
}

subtest 'kit_dir stashes an absolute path' => sub {
	my $ret = Genesis::Kit::Validator::kit_dir($kit);
	like $ret, qr{^/},                'returns an absolute path';
	is $Genesis::Kit::Validator::KIT_DIR, $ret, 'global is set';
};

subtest 'kit_dir dies on nonexistent path' => sub {
	eval { Genesis::Kit::Validator::kit_dir('/nonexistent-xyzzy-99') };
	like $@, qr/not readable/, 'bad path -> die';
};

subtest 'test_env builds an Environment and forwards to Runner' => sub {
	Genesis::Kit::Validator::kit_dir($kit);
	@collected = ();

	my $env = Genesis::Kit::Validator::test_env(
		name         => 'aws',
		cloud_config => 'aws',
	);
	isa_ok $env, 'Genesis::Kit::Validator::Environment';
	is $env->name, 'aws';
	is $env->cloud_config, 'aws';

	is scalar(@collected), 1, 'Runner->run invoked once';
	isa_ok $collected[0]{env}, 'Genesis::Kit::Validator::Environment';
	is $collected[0]{env}->name, 'aws';
	is $collected[0]{opts}{kit_dir}, $Genesis::Kit::Validator::KIT_DIR,
		'kit_dir passed through to Runner';
};

subtest 'test_env accumulates environments across calls' => sub {
	Genesis::Kit::Validator::kit_dir($kit);
	@collected = ();
	@Genesis::Kit::Validator::ENVIRONMENTS = ();

	Genesis::Kit::Validator::test_env(name => 'aws');
	Genesis::Kit::Validator::test_env(name => 'proto-aws');
	Genesis::Kit::Validator::test_env(name => 'azure');

	is scalar(@collected), 3, 'three Runner->run calls';
	is_deeply [map { $_->{env}->name } @collected],
	          [qw/aws proto-aws azure/],
	          'envs preserved in declaration order';
	is scalar(@Genesis::Kit::Validator::ENVIRONMENTS), 3,
		'environments stashed on package-level array';
};

subtest 'KIT_VALIDATOR_FOCUS filters which envs actually run' => sub {
	Genesis::Kit::Validator::kit_dir($kit);
	@collected = ();
	@Genesis::Kit::Validator::ENVIRONMENTS = ();

	local $ENV{KIT_VALIDATOR_FOCUS} = 'aws:azure';
	Genesis::Kit::Validator::test_env(name => 'aws');       # runs
	Genesis::Kit::Validator::test_env(name => 'proto-aws'); # skipped
	Genesis::Kit::Validator::test_env(name => 'azure');     # runs

	is scalar(@collected), 2, 'only two envs matched the focus set';
	is_deeply [map { $_->{env}->name } @collected], [qw/aws azure/],
		'aws + azure ran; proto-aws skipped';
	is scalar(@Genesis::Kit::Validator::ENVIRONMENTS), 3,
		'all three envs still recorded in the declaration list';
};

done_testing;
