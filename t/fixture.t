#!perl
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use_ok 'Kit::Validator::Fixture';

# Fixture resolves <kit_dir>/spec/<category>/<name>.yml paths.  It is
# not responsible for verifying that a file exists -- that is the
# runner's concern per-step.  It IS responsible for consistent path
# construction and for reporting whether a path is present, so that
# the runner can decide whether to bootstrap a stub.

my $kit = tempdir(CLEANUP => 1);
make_path("$kit/spec/deployments", "$kit/spec/cloud_configs",
	"$kit/spec/results", "$kit/spec/vault");

for my $rel (qw(spec/deployments/aws.yml spec/cloud_configs/aws.yml
                spec/results/aws.yml)) {
	open my $fh, '>', "$kit/$rel" or die $!;
	print $fh "---\nplaceholder: yes\n";
	close $fh;
}

subtest 'constructor requires kit_dir' => sub {
	eval { Kit::Validator::Fixture->new() };
	like $@, qr/kit_dir is required/, 'no args -> die';

	eval { Kit::Validator::Fixture->new(kit_dir => '/nonexistent-xyzzy-42') };
	like $@, qr/kit_dir does not exist/, 'bad path -> die';
};

subtest 'path resolves category + name to spec/<cat>/<name>.yml' => sub {
	my $fx = Kit::Validator::Fixture->new(kit_dir => $kit);
	is $fx->path('deployments', 'aws'),   "$kit/spec/deployments/aws.yml";
	is $fx->path('cloud_configs', 'aws'), "$kit/spec/cloud_configs/aws.yml";
	is $fx->path('results', 'aws'),       "$kit/spec/results/aws.yml";
};

subtest 'exists() reflects on-disk state' => sub {
	my $fx = Kit::Validator::Fixture->new(kit_dir => $kit);
	ok  $fx->exists('deployments', 'aws'),   'present file is exists=true';
	ok !$fx->exists('deployments', 'gcp'),   'absent file is exists=false';
	ok !$fx->exists('exodus',      'aws'),   'absent category is exists=false';
};

subtest 'read() slurps YAML file, returns raw text' => sub {
	my $fx = Kit::Validator::Fixture->new(kit_dir => $kit);
	my $body = $fx->read('deployments', 'aws');
	like $body, qr/placeholder: yes/, 'body contains file content';
};

subtest 'read() dies on missing file with resolvable path in message' => sub {
	my $fx = Kit::Validator::Fixture->new(kit_dir => $kit);
	eval { $fx->read('deployments', 'gcp') };
	like $@, qr{spec/deployments/gcp.yml}, 'error names the resolved path';
};

subtest 'write() creates the parent dir if missing' => sub {
	my $fx = Kit::Validator::Fixture->new(kit_dir => $kit);
	$fx->write('credhub', 'aws', "---\nfoo: bar\n");
	ok -d "$kit/spec/credhub",           'category dir created';
	ok -f "$kit/spec/credhub/aws.yml",   'file created';
	is $fx->read('credhub', 'aws'), "---\nfoo: bar\n", 'roundtrip content';
};

done_testing;
