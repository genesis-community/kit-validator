#!perl
use strict;
use warnings;
use Test::More;
use Test::Deep;

use_ok 'Kit::Validator::Environment';
use_ok 'Kit::Validator::Runner::Cmd';

# The Cmd builders test 'genesis' argv[0] by default.  When the
# suite runs with KIT_VALIDATOR_GENESIS=g32 (as the integration
# test does), the override would poison every subtest below --
# except the one that tests the override itself.  Scope it to
# undef for the file.
delete local $ENV{KIT_VALIDATOR_GENESIS};

# Pure command builders.  Given an Environment + workdir + fixture
# resolver, they emit the exact arg list each subprocess call needs.
# The Runner orchestrator threads these through Genesis::run; tests
# assert the arg list is correct without shelling out.
#
# Anchor for parity: testkit/testing/genesis.go lines 86-108 (init),
# 128-139 (check), 202-215 (manifest), and testkit/testing/bosh.go
# 34-47 (bosh int).

my $ENV_NAME = 'aws';
my $KIT_NAME = 'bosh';
my $KIT_DIR  = '/kits/bosh';
my $WORKDIR  = '/tmp/kv-workdir-42';
my $VAULT    = 'local_vault_kv-aws_1234';

sub env {
	my (%o) = @_;
	Kit::Validator::Environment->new(name => $ENV_NAME, %o);
}

subtest 'genesis_init_cmd: minimal fields' => sub {
	my $cmd = Kit::Validator::Runner::Cmd::genesis_init_cmd(
		kit_name  => $KIT_NAME,
		kit_dir   => $KIT_DIR,
		workdir   => $WORKDIR,
		vault     => $VAULT,
	);
	is_deeply $cmd, [
		'genesis', 'init',
		'--link-dev-kit', $KIT_DIR,
		'--vault', $VAULT,
		'--cwd', $WORKDIR,
		'--directory', 'deployments',
		$KIT_NAME,
	], 'init command has all fields in the right positions';
};

subtest 'genesis_check_cmd: no cloud/runtime configs' => sub {
	my $env = env();
	my $cmd = Kit::Validator::Runner::Cmd::genesis_check_cmd(
		env      => $env,
		fixture_dir => '/kits/bosh/spec',
	);
	is_deeply $cmd, [
		'genesis', 'check',
		'--cwd', 'deployments/',
		'--no-manifest',
		'--no-stemcells',
		$ENV_NAME,
	], 'no -c flags when neither cloud nor runtime configured';
};

subtest 'genesis_check_cmd: cloud config only' => sub {
	my $env = env(cloud_config => 'aws');
	my $cmd = Kit::Validator::Runner::Cmd::genesis_check_cmd(
		env         => $env,
		fixture_dir => '/kits/bosh/spec',
	);
	is_deeply $cmd, [
		'genesis', 'check',
		'--cwd', 'deployments/',
		'--no-manifest',
		'--no-stemcells',
		'-c', 'cloud=/kits/bosh/spec/cloud_configs/aws.yml',
		$ENV_NAME,
	], 'cloud config gets -c cloud=<path>';
};

subtest 'genesis_check_cmd: cloud + runtime configs' => sub {
	my $env = env(cloud_config => 'aws', runtime_config => 'dns');
	my $cmd = Kit::Validator::Runner::Cmd::genesis_check_cmd(
		env         => $env,
		fixture_dir => '/kits/bosh/spec',
	);
	is_deeply $cmd, [
		'genesis', 'check',
		'--cwd', 'deployments/',
		'--no-manifest',
		'--no-stemcells',
		'-c', 'cloud=/kits/bosh/spec/cloud_configs/aws.yml',
		'-c', 'runtime=/kits/bosh/spec/runtime_configs/dns.yml',
		$ENV_NAME,
	], 'both configs land as consecutive -c flags';
};

subtest 'genesis_check_cmd: cpi stub path adds -c cpi=<path>' => sub {
	# Genesis 1146a669e opportunistically appends `cpi` to required_configs
	# for the check/manifest hooks.  Without a value on disk, download_configs
	# reaches for the parent BOSH director and bails.  The Runner writes an
	# empty stub into the workdir and passes it via cpi_stub_path.
	my $env = env(cloud_config => 'aws');
	my $cmd = Kit::Validator::Runner::Cmd::genesis_check_cmd(
		env           => $env,
		fixture_dir   => '/kits/bosh/spec',
		cpi_stub_path => '/tmp/kv-wd/empty-cpi.yml',
	);
	is_deeply $cmd, [
		'genesis', 'check',
		'--cwd', 'deployments/',
		'--no-manifest',
		'--no-stemcells',
		'-c', 'cloud=/kits/bosh/spec/cloud_configs/aws.yml',
		'-c', 'cpi=/tmp/kv-wd/empty-cpi.yml',
		$ENV_NAME,
	], 'stub cpi lands as -c cpi=<workdir-path> when env has no cpi_config';
};

subtest 'genesis_check_cmd: env->cpi_config overrides the stub' => sub {
	# Opt-in per-env CPI fixture wins over the workdir stub -- used to
	# exercise multi-CPI configs, IAM profile variants, etc.
	my $env = env(cloud_config => 'aws', cpi_config => 'aws-multi-iam');
	my $cmd = Kit::Validator::Runner::Cmd::genesis_check_cmd(
		env           => $env,
		fixture_dir   => '/kits/bosh/spec',
		cpi_stub_path => '/tmp/kv-wd/empty-cpi.yml',
	);
	is_deeply $cmd, [
		'genesis', 'check',
		'--cwd', 'deployments/',
		'--no-manifest',
		'--no-stemcells',
		'-c', 'cloud=/kits/bosh/spec/cloud_configs/aws.yml',
		'-c', 'cpi=/kits/bosh/spec/cpi_configs/aws-multi-iam.yml',
		$ENV_NAME,
	], 'env->cpi_config points at spec/cpi_configs/<name>.yml';
};

subtest 'genesis_manifest_cmd: cpi stub also plumbs through' => sub {
	my $env = env(cloud_config => 'aws');
	my $cmd = Kit::Validator::Runner::Cmd::genesis_manifest_cmd(
		env           => $env,
		fixture_dir   => '/kits/bosh/spec',
		cpi_stub_path => '/tmp/kv-wd/empty-cpi.yml',
	);
	is_deeply $cmd, [
		'genesis', "deployments/$ENV_NAME", 'manifest',
		'--type=unredacted',
		'-c', 'cloud=/kits/bosh/spec/cloud_configs/aws.yml',
		'-c', 'cpi=/tmp/kv-wd/empty-cpi.yml',
	], 'manifest command carries the same cpi stub as check';
};

subtest 'genesis_manifest_cmd: env name is used in the subject position' => sub {
	my $env = env(cloud_config => 'aws');
	my $cmd = Kit::Validator::Runner::Cmd::genesis_manifest_cmd(
		env         => $env,
		fixture_dir => '/kits/bosh/spec',
	);
	is_deeply $cmd, [
		'genesis', "deployments/$ENV_NAME", 'manifest',
		'--type=unredacted',
		'-c', 'cloud=/kits/bosh/spec/cloud_configs/aws.yml',
	], 'manifest subject is deployments/<env>, not just <env>';
};

subtest 'bosh_int_cmd: manifest + vars-file only' => sub {
	my $cmd = Kit::Validator::Runner::Cmd::bosh_int_cmd(
		manifest_path  => '/tmp/manifest.yml',
		bosh_vars_path => '/tmp/bosh-vars.yml',
	);
	is_deeply $cmd, [
		'bosh', 'int',
		'/tmp/manifest.yml',
		'--var-errs',
		'--var-errs-unused',
		'--vars-file', '/tmp/bosh-vars.yml',
	], 'no credhub vars/stub -> just bosh-vars';
};

subtest 'bosh_int_cmd: with credhub_variables and credhub stub' => sub {
	my $cmd = Kit::Validator::Runner::Cmd::bosh_int_cmd(
		manifest_path       => '/tmp/manifest.yml',
		bosh_vars_path      => '/tmp/bosh-vars.yml',
		credhub_vars_path   => '/tmp/credhub-vars.yml',
		credhub_stub_path   => '/tmp/credhub-stub.yml',
	);
	is_deeply $cmd, [
		'bosh', 'int',
		'/tmp/manifest.yml',
		'--var-errs',
		'--var-errs-unused',
		'--vars-file', '/tmp/bosh-vars.yml',
		'--vars-file', '/tmp/credhub-vars.yml',
		'--vars-file', '/tmp/credhub-stub.yml',
	], 'credhub-vars + credhub-stub appended in order';
};

subtest 'spruce_diff_cmd' => sub {
	my $cmd = Kit::Validator::Runner::Cmd::spruce_diff_cmd(
		golden_path => '/kits/bosh/spec/results/aws.yml',
		actual_path => '/tmp/actual.yml',
	);
	is_deeply $cmd, [
		'spruce', 'diff',
		'/kits/bosh/spec/results/aws.yml',
		'/tmp/actual.yml',
	], 'spruce diff <golden> <actual>';
};

subtest 'genesis_check_secrets_cmd' => sub {
	my $env = env();
	my $cmd = Kit::Validator::Runner::Cmd::genesis_check_secrets_cmd(env => $env);
	is_deeply $cmd, [
		'genesis', 'check-secrets',
		'--no-color', '-lm', '-v',
		'--cwd', 'deployments/',
		$ENV_NAME,
		'type=provided',
	], 'check-secrets with -lm and provided-only filter';
};

subtest 'genesis_add_secrets_cmd' => sub {
	my $env = env();
	my $cmd = Kit::Validator::Runner::Cmd::genesis_add_secrets_cmd(env => $env);
	is_deeply $cmd, [
		'genesis', 'add-secrets',
		'--cwd', 'deployments/',
		$ENV_NAME,
	], 'add-secrets minimal form';
};

subtest 'testing_env: builds the GENESIS_TESTING_* env vars for genesis calls' => sub {
	my $env = env(cpi => 'aws');
	my $vars = Kit::Validator::Runner::Cmd::testing_env(env => $env);
	cmp_deeply $vars, {
		GENESIS_TESTING_BOSH_CPI                     => 'aws',
		GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY  => 'true',
		GENESIS_TESTING                              => 'yes',
		GENESIS_BOSH_VERIFIED                        => $ENV_NAME,
	}, 'four env vars mirror testkit/testing/genesis.go:333-341';
};

subtest 'testing_env: empty cpi still emits the key (blank)' => sub {
	my $env = env();
	my $vars = Kit::Validator::Runner::Cmd::testing_env(env => $env);
	is $vars->{GENESIS_TESTING_BOSH_CPI}, '',
		'blank cpi -> blank value (parity with testkit default)';
};

subtest 'KIT_VALIDATOR_GENESIS overrides argv[0] for every genesis-* cmd' => sub {
	local $ENV{KIT_VALIDATOR_GENESIS} = 'g32';
	my $env = env(cloud_config => 'aws');
	is Kit::Validator::Runner::Cmd::genesis_init_cmd(
		kit_name => 'x', kit_dir => 'k', workdir => 'w', vault => 'v')->[0], 'g32';
	is Kit::Validator::Runner::Cmd::genesis_check_cmd(
		env => $env, fixture_dir => '/x')->[0], 'g32';
	is Kit::Validator::Runner::Cmd::genesis_manifest_cmd(
		env => $env, fixture_dir => '/x')->[0], 'g32';
	is Kit::Validator::Runner::Cmd::genesis_check_secrets_cmd(env => $env)->[0], 'g32';
	is Kit::Validator::Runner::Cmd::genesis_add_secrets_cmd(env => $env)->[0], 'g32';
};

done_testing;
