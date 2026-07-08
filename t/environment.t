#!perl
use strict;
use warnings;
use Test::More;

use_ok 'Kit::Validator::Environment';

# Environment field defaults + coercion.  The object is a value carrier
# for the runner: fields describe which fixture files to load and how
# to assert.  Its constructor must be forgiving of missing optional
# fields and strict about the one required field (name).

subtest 'name is required' => sub {
	eval { Kit::Validator::Environment->new() };
	like $@, qr/name is required/, 'no args -> die';

	eval { Kit::Validator::Environment->new(name => '') };
	like $@, qr/name is required/, 'empty name -> die';
};

subtest 'minimal env: name only, sensible defaults' => sub {
	my $env = Kit::Validator::Environment->new(name => 'aws');
	is $env->name, 'aws',                'name preserved';
	is $env->cloud_config,      undef,   'cloud_config defaults to undef';
	is $env->runtime_config,    undef,   'runtime_config defaults to undef';
	is $env->credhub_vars,      undef,   'credhub_vars defaults to undef';
	is $env->exodus,            undef,   'exodus defaults to undef';
	is $env->cpi,               '',      'cpi defaults to empty string';
	is_deeply $env->ops,        [],      'ops defaults to empty arrayref';
	is_deeply $env->output_matchers, {}, 'output_matchers defaults to empty hashref';
	ok !$env->focus,                     'focus defaults to false';
};

subtest 'full env: all fields settable' => sub {
	my $env = Kit::Validator::Environment->new(
		name           => 'aws',
		cloud_config   => 'aws',
		runtime_config => 'dns',
		credhub_vars   => 'aws',
		exodus         => 'old-version',
		cpi            => 'aws',
		ops            => [qw/test-ops-override/],
		focus          => 1,
		output_matchers => {
			genesis_check    => qr/kit version .* is too old/,
			genesis_manifest => qr/kit version .* is too old/,
		},
	);
	is $env->name,           'aws';
	is $env->cloud_config,   'aws';
	is $env->runtime_config, 'dns';
	is $env->credhub_vars,   'aws';
	is $env->exodus,         'old-version';
	is $env->cpi,            'aws';
	is_deeply $env->ops, [qw/test-ops-override/];
	ok $env->focus;
	is ref $env->output_matchers->{genesis_check}, 'Regexp',
		'output_matcher regex passthrough';
};

subtest 'output_matchers keys are validated' => sub {
	eval {
		Kit::Validator::Environment->new(
			name            => 'x',
			output_matchers => { bogus_matcher => qr/./ },
		);
	};
	like $@, qr/unknown output_matcher: bogus_matcher/,
		'unknown key -> die (typo protection)';
};

subtest 'output_matchers values must be Regexp' => sub {
	eval {
		Kit::Validator::Environment->new(
			name            => 'x',
			output_matchers => { genesis_check => 'string not regex' },
		);
	};
	like $@, qr/output_matcher .* must be a Regexp/,
		'non-regex value -> die';
};

done_testing;
