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

use_ok 'Kit::Validator';
use_ok 'Kit::Validator::Runner';   # load before monkey-patching ::run

my $kit = tempdir(CLEANUP => 1);
make_path("$kit/spec");

my @collected;
{
	no warnings qw/redefine once/;
	*Kit::Validator::Runner::run = sub {
		my ($class, $env, %opts) = @_;
		push @collected, {env => $env, opts => \%opts};
	};
}

subtest 'kit_dir stashes an absolute path' => sub {
	my $ret = Kit::Validator::kit_dir($kit);
	like $ret, qr{^/},                'returns an absolute path';
	is $Kit::Validator::KIT_DIR, $ret, 'global is set';
};

subtest 'kit_dir dies on nonexistent path' => sub {
	eval { Kit::Validator::kit_dir('/nonexistent-xyzzy-99') };
	like $@, qr/not readable/, 'bad path -> die';
};

subtest 'test_env builds an Environment and forwards to Runner' => sub {
	Kit::Validator::kit_dir($kit);
	@collected = ();

	my $env = Kit::Validator::test_env(
		name         => 'aws',
		cloud_config => 'aws',
	);
	isa_ok $env, 'Kit::Validator::Environment';
	is $env->name, 'aws';
	is $env->cloud_config, 'aws';

	is scalar(@collected), 1, 'Runner->run invoked once';
	isa_ok $collected[0]{env}, 'Kit::Validator::Environment';
	is $collected[0]{env}->name, 'aws';
	is $collected[0]{opts}{kit_dir}, $Kit::Validator::KIT_DIR,
		'kit_dir passed through to Runner';
};

subtest 'test_env accumulates environments across calls' => sub {
	Kit::Validator::kit_dir($kit);
	@collected = ();
	@Kit::Validator::ENVIRONMENTS = ();

	Kit::Validator::test_env(name => 'aws');
	Kit::Validator::test_env(name => 'proto-aws');
	Kit::Validator::test_env(name => 'azure');

	is scalar(@collected), 3, 'three Runner->run calls';
	is_deeply [map { $_->{env}->name } @collected],
	          [qw/aws proto-aws azure/],
	          'envs preserved in declaration order';
	is scalar(@Kit::Validator::ENVIRONMENTS), 3,
		'environments stashed on package-level array';
};

subtest 'KIT_VALIDATOR_FOCUS filters which envs actually run' => sub {
	Kit::Validator::kit_dir($kit);
	@collected = ();
	@Kit::Validator::ENVIRONMENTS = ();

	local $ENV{KIT_VALIDATOR_FOCUS} = 'aws:azure';
	Kit::Validator::test_env(name => 'aws');       # runs
	Kit::Validator::test_env(name => 'proto-aws'); # skipped
	Kit::Validator::test_env(name => 'azure');     # runs

	is scalar(@collected), 2, 'only two envs matched the focus set';
	is_deeply [map { $_->{env}->name } @collected], [qw/aws azure/],
		'aws + azure ran; proto-aws skipped';
	is scalar(@Kit::Validator::ENVIRONMENTS), 3,
		'all three envs still recorded in the declaration list';
};

done_testing;
