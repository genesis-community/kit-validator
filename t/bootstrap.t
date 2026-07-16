#!perl
use strict;
use warnings;
use Test::More;
use Test::Deep;

use_ok 'Genesis::Kit::Validator::Bootstrap';

# Bootstrap is a set of pure functions that turn raw safe-export /
# bosh-vars-store output into the tokenized `<!{meta.vault}/...!>` and
# `<!{credhub}:...!>` stubs kits commit under spec/vault/ and
# spec/credhub/.  Testkit's Go equivalent lives at:
#   - vault.go:83-94, 126-147 (vault token rewrite)
#   - bosh.go:49-71, 86-100  (credhub token rewrite)

subtest 'env_vault_base: single-segment env' => sub {
	is Genesis::Kit::Validator::Bootstrap::env_vault_base('aws', 'bosh'),
	   'secret/aws/bosh',
	   'env=aws, kit=bosh -> secret/aws/bosh';
};

subtest 'env_vault_base: dashed env -> slashed path' => sub {
	is Genesis::Kit::Validator::Bootstrap::env_vault_base('us-east-prod', 'bosh'),
	   'secret/us/east/prod/bosh',
	   'dashes in env name become path separators';
};

subtest 'tokenize_vault_export: single path, single key' => sub {
	my $out = Genesis::Kit::Validator::Bootstrap::tokenize_vault_export(
		{'secret/aws/bosh/admin' => {password => 'realsecret'}},
		env_name => 'aws',
		kit_name => 'bosh',
	);
	cmp_deeply $out, {
		'secret/aws/bosh/admin' => {
			password => '<!{meta.vault}/admin:password!>',
		},
	}, 'subpath = admin (base stripped), key = password';
};

subtest 'tokenize_vault_export: multi-segment subpath' => sub {
	my $out = Genesis::Kit::Validator::Bootstrap::tokenize_vault_export(
		{'secret/aws/bosh/blobstore/agent' => {password => 'x'}},
		env_name => 'aws',
		kit_name => 'bosh',
	);
	is $out->{'secret/aws/bosh/blobstore/agent'}{password},
	   '<!{meta.vault}/blobstore/agent:password!>',
	   'nested subpath preserved in token';
};

subtest 'tokenize_vault_export: multiple keys under one path' => sub {
	my $out = Genesis::Kit::Validator::Bootstrap::tokenize_vault_export(
		{'secret/aws/bosh/certs/ca' => {
			certificate => 'PEM',
			key         => 'PEM',
			combined    => 'PEM',
		}},
		env_name => 'aws',
		kit_name => 'bosh',
	);
	cmp_deeply $out, {
		'secret/aws/bosh/certs/ca' => {
			certificate => '<!{meta.vault}/certs/ca:certificate!>',
			key         => '<!{meta.vault}/certs/ca:key!>',
			combined    => '<!{meta.vault}/certs/ca:combined!>',
		},
	}, 'all keys under one path get individual tokens';
};

subtest 'tokenize_vault_export: dashed env base is stripped correctly' => sub {
	my $out = Genesis::Kit::Validator::Bootstrap::tokenize_vault_export(
		{'secret/us/east/prod/bosh/admin' => {password => 'x'}},
		env_name => 'us-east-prod',
		kit_name => 'bosh',
	);
	is $out->{'secret/us/east/prod/bosh/admin'}{password},
	   '<!{meta.vault}/admin:password!>',
	   'multi-segment env base is stripped, subpath token clean';
};

subtest 'tokenize_vault_export: path outside vault base is left untouched (defensive)' => sub {
	my $out = Genesis::Kit::Validator::Bootstrap::tokenize_vault_export(
		{
			'secret/aws/bosh/admin' => {password => 'x'},
			'secret/shared/config'  => {url => 'https://vault'},
		},
		env_name => 'aws',
		kit_name => 'bosh',
	);
	is $out->{'secret/aws/bosh/admin'}{password},
	   '<!{meta.vault}/admin:password!>',
	   'in-scope path tokenized';
	is $out->{'secret/shared/config'}{url}, 'https://vault',
	   'out-of-scope path left alone (safe export scope errors will be caught elsewhere)';
};

subtest 'tokenize_credhub_vars: scalar variable' => sub {
	my $out = Genesis::Kit::Validator::Bootstrap::tokenize_credhub_vars({
		blobstore_admin_users_password => 'generated-password',
	});
	cmp_deeply $out, {
		blobstore_admin_users_password =>
			'<!{credhub}:blobstore_admin_users_password!>',
	}, 'scalar var -> flat token';
};

subtest 'tokenize_credhub_vars: certificate variable with sub-keys' => sub {
	my $out = Genesis::Kit::Validator::Bootstrap::tokenize_credhub_vars({
		application_ca => {
			ca          => '---PEM---',
			certificate => '---PEM---',
			private_key => '---PEM---',
		},
	});
	cmp_deeply $out, {
		application_ca => {
			ca          => '<!{credhub}:application_ca.ca!>',
			certificate => '<!{credhub}:application_ca.certificate!>',
			private_key => '<!{credhub}:application_ca.private_key!>',
		},
	}, 'hash var -> per-subkey tokens with dot separator';
};

subtest 'tokenize_credhub_vars: mixed scalar + hash variables' => sub {
	my $out = Genesis::Kit::Validator::Bootstrap::tokenize_credhub_vars({
		blobstore_secret => 'raw',
		router_ca        => {ca => 'PEM', certificate => 'PEM'},
	});
	is $out->{blobstore_secret}, '<!{credhub}:blobstore_secret!>';
	is $out->{router_ca}{ca}, '<!{credhub}:router_ca.ca!>';
	is $out->{router_ca}{certificate}, '<!{credhub}:router_ca.certificate!>';
};

subtest 'tokenize_credhub_vars: input is not mutated' => sub {
	my $vars = {sec => 'x', ca => {c => 'PEM'}};
	my $vars_before = {sec => 'x', ca => {c => 'PEM'}};
	Genesis::Kit::Validator::Bootstrap::tokenize_credhub_vars($vars);
	cmp_deeply $vars, $vars_before, 'input hash preserved';
};

subtest 'tokenize_vault_export: input is not mutated' => sub {
	my $exp = {'secret/aws/bosh/admin' => {password => 'x'}};
	my $exp_before = {'secret/aws/bosh/admin' => {password => 'x'}};
	Genesis::Kit::Validator::Bootstrap::tokenize_vault_export(
		$exp, env_name => 'aws', kit_name => 'bosh'
	);
	cmp_deeply $exp, $exp_before, 'input hash preserved';
};

done_testing;
