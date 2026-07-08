#!perl
use strict;
use warnings;
use Test::More;
use Test::Deep;

use_ok 'Kit::Validator::Prune';

# Kit::Validator::Prune::prune_manifest strips the same keys the Go
# testkit does (testkit/testing/genesis.go:20-26 + 153-186):
#   - always: meta, pipeline, params, bosh-variables, kit, genesis,
#     compilation
#   - unless proto feature: resource_pools, vm_types, disk_pools,
#     disk_types, networks, azs, vm_extensions
#   - under exodus: version, dated, deployer, kit_name, kit_version,
#     vault_base, kit_is_dev, upgarding (yes, misspelled -- carry it
#     forward for parity)
#
# It also splits out bosh-variables into a separate return, since the
# runner needs those for `bosh int --vars-file`.

sub base_manifest {
	return {
		name  => 'test-env',
		meta  => {vault => 'secret/x'},
		pipeline => {name => 'ci'},
		params => {static_ips => 5},
		'bosh-variables' => {some => 'var'},
		kit => {name => 'bosh'},
		genesis => {env => 'test-env'},
		compilation => {workers => 4},
		instance_groups => [{name => 'bosh', instances => 1}],
		releases => [{name => 'bosh', version => '1.0.0', url => 'https://x/y', sha1 => 'abc'}],
		stemcells => [{alias => 'default', os => 'ubuntu', version => 'latest'}],
		update => {canaries => 1},
		exodus => {
			version      => '3.2.0',
			dated        => '2026-07-07',
			deployer     => 'ci',
			kit_name     => 'bosh',
			kit_version  => '4.1.0',
			vault_base   => 'secret/x',
			kit_is_dev   => 'no',
			upgarding    => 'no',
			target_url   => 'https://bosh.example',
			admin_user   => 'admin',
		},
	};
}

subtest 'always drops top-level meta/pipeline/params/kit/genesis/compilation' => sub {
	my $m = base_manifest();
	my ($pruned, $bosh_vars) = Kit::Validator::Prune::prune_manifest($m, {is_proto => 0});
	ok !exists $pruned->{meta},        'meta dropped';
	ok !exists $pruned->{pipeline},    'pipeline dropped';
	ok !exists $pruned->{params},      'params dropped';
	ok !exists $pruned->{kit},         'kit dropped';
	ok !exists $pruned->{genesis},     'genesis dropped';
	ok !exists $pruned->{compilation}, 'compilation dropped';
};

subtest 'bosh-variables peeled off into second return, dropped from manifest' => sub {
	my $m = base_manifest();
	my ($pruned, $bosh_vars) = Kit::Validator::Prune::prune_manifest($m, {is_proto => 0});
	ok !exists $pruned->{'bosh-variables'}, 'bosh-variables dropped from manifest';
	cmp_deeply $bosh_vars, {some => 'var'}, 'bosh-variables returned separately';
};

subtest 'non-proto env: also drops network-shape top-level keys' => sub {
	my $m = base_manifest();
	$m->{$_} = 'sentinel' for qw/resource_pools vm_types disk_pools disk_types networks azs vm_extensions/;
	my ($pruned) = Kit::Validator::Prune::prune_manifest($m, {is_proto => 0});
	ok !exists $pruned->{$_}, "$_ dropped for non-proto" for qw/resource_pools vm_types disk_pools disk_types networks azs vm_extensions/;
};

subtest 'proto env: retains network-shape top-level keys' => sub {
	my $m = base_manifest();
	$m->{$_} = "sentinel-$_" for qw/resource_pools vm_types networks azs/;
	my ($pruned) = Kit::Validator::Prune::prune_manifest($m, {is_proto => 1});
	is $pruned->{resource_pools}, 'sentinel-resource_pools', 'resource_pools retained for proto';
	is $pruned->{vm_types},       'sentinel-vm_types',       'vm_types retained for proto';
	is $pruned->{networks},       'sentinel-networks',       'networks retained for proto';
	is $pruned->{azs},            'sentinel-azs',            'azs retained for proto';
};

subtest 'exodus subkeys stripped, rest retained' => sub {
	my $m = base_manifest();
	my ($pruned) = Kit::Validator::Prune::prune_manifest($m, {is_proto => 0});
	ok  exists $pruned->{exodus},                 'exodus block retained';
	is $pruned->{exodus}{target_url}, 'https://bosh.example', 'non-stripped exodus key preserved';
	is $pruned->{exodus}{admin_user}, 'admin',                'non-stripped exodus key preserved';
	ok !exists $pruned->{exodus}{$_}, "exodus.$_ dropped"
		for qw/version dated deployer kit_name kit_version vault_base kit_is_dev upgarding/;
};

subtest 'preserves instance_groups, releases, stemcells, update, name' => sub {
	my $m = base_manifest();
	my ($pruned) = Kit::Validator::Prune::prune_manifest($m, {is_proto => 0});
	is $pruned->{name}, 'test-env';
	cmp_deeply $pruned->{releases},  [{name => 'bosh', version => '1.0.0', url => 'https://x/y', sha1 => 'abc'}];
	cmp_deeply $pruned->{stemcells}, [{alias => 'default', os => 'ubuntu', version => 'latest'}];
	is $pruned->{instance_groups}[0]{name}, 'bosh';
	is $pruned->{update}{canaries}, 1;
};

subtest 'null/absent exodus: no error' => sub {
	my $m = base_manifest();
	delete $m->{exodus};
	my ($pruned) = Kit::Validator::Prune::prune_manifest($m, {is_proto => 0});
	ok !exists $pruned->{exodus}, 'exodus stays absent';
};

subtest 'null/absent bosh-variables: returns empty hashref' => sub {
	my $m = base_manifest();
	delete $m->{'bosh-variables'};
	my ($pruned, $bosh_vars) = Kit::Validator::Prune::prune_manifest($m, {is_proto => 0});
	cmp_deeply $bosh_vars, {}, 'empty hashref when absent';
};

subtest 'input is not mutated' => sub {
	my $m = base_manifest();
	my $m_before = base_manifest();
	Kit::Validator::Prune::prune_manifest($m, {is_proto => 0});
	cmp_deeply $m, $m_before, 'prune_manifest is a pure function';
};

done_testing;
