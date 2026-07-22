#!perl
use strict;
use warnings;
use Test::More;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec;
use FindBin;
use Cwd qw/abs_path/;

# bin/genesis-kit-validator is a thin CLI wrapper around prove(1) and the
# validator's spec suite.  Its user-visible contracts are:
#   (1) --help exits 0 and prints usage
#   (2) --regenerate and --regenerate-all refuse to run without --focus
#       so bulk cache wipes are always explicit
#   (3) --regenerate removes spec/results/<env>.{yml,yamls.txt} for
#       each focused env; --regenerate-all also removes
#       spec/vault/<env>.yml so vault caches re-materialize on the
#       next run
#   (4) --genesis <path> sets KIT_VALIDATOR_GENESIS; --genesis-lib
#       <path> sets GENESIS_LIB (Genesis's own dev-loop lib override,
#       distinct from KIT_VALIDATOR_LIB).  CLI flags override any
#       pre-existing env values.
#   (5) KIT_VALIDATOR_LIB (the validator's own lib) auto-derives
#       from dirname(script)/../lib when unset, so cloning the repo
#       and invoking bin/... works without extra env setup.
#
# These tests exercise the script as a subprocess -- the CLI is orchestration,
# and its observable behavior is exit codes, stderr, and side effects on
# the filesystem.

my $BIN = abs_path("$FindBin::Bin/../bin/genesis-kit-validator");
ok -x $BIN, "bin/genesis-kit-validator is executable at $BIN";

sub write_file {
	my ($path, $content) = @_;
	open my $fh, '>', $path or die "open $path: $!";
	print {$fh} $content;
	close $fh or die "close $path: $!";
}

sub run_bin {
	my (%opt) = @_;
	my $args = $opt{args} // [];
	my $env  = $opt{env}  // {};

	my $out_file = File::Temp->new(SUFFIX => '.out');
	my $err_file = File::Temp->new(SUFFIX => '.err');

	my $pid = fork();
	die "fork failed: $!" unless defined $pid;
	if ($pid == 0) {
		for my $k (keys %$env) {
			if (defined $env->{$k}) { $ENV{$k} = $env->{$k} }
			else                    { delete $ENV{$k}       }
		}
		open STDOUT, '>', $out_file->filename or die $!;
		open STDERR, '>', $err_file->filename or die $!;
		exec $BIN, @$args;
		die "exec failed: $!";
	}
	waitpid $pid, 0;
	my $status = $? >> 8;
	my $out = do { local (@ARGV, $/) = $out_file->filename; <> } // '';
	my $err = do { local (@ARGV, $/) = $err_file->filename; <> } // '';
	return ($out, $err, $status);
}

subtest '--help exits 0 and prints usage' => sub {
	my ($out, $err, $rc) = run_bin(args => ['--help']);
	is $rc, 0, 'exit 0';
	like $out, qr/Usage:.*genesis-kit-validator/, 'usage banner present';
	like $out, qr/--focus/,          'documents --focus';
	like $out, qr/--regenerate\b/,   'documents --regenerate';
	like $out, qr/--regenerate-all/, 'documents --regenerate-all';
	like $out, qr/--genesis\b/,      'documents --genesis';
	like $out, qr/--genesis-lib/,    'documents --genesis-lib';
};

subtest '--regenerate without --focus errors out' => sub {
	my ($out, $err, $rc) = run_bin(args => ['run', '--regenerate']);
	isnt $rc, 0, 'non-zero exit';
	like $err, qr/--regenerate.*requires.*--focus/i,
		'error names --regenerate and --focus';
};

subtest '--regenerate-all without --focus errors out' => sub {
	my ($out, $err, $rc) = run_bin(args => ['run', '--regenerate-all']);
	isnt $rc, 0, 'non-zero exit';
	like $err, qr/--regenerate-all.*requires.*--focus/i,
		'error names --regenerate-all and --focus';
};

subtest '--regenerate removes goldens (.yml + .yamls.txt) for focused envs' => sub {
	my $spec_dir = tempdir(CLEANUP => 1);
	make_path("$spec_dir/results", "$spec_dir/vault");

	for my $env (qw/proto-foo bar/) {
		write_file("$spec_dir/results/$env.yml",       "y");
		write_file("$spec_dir/results/$env.yamls.txt", "t");
		write_file("$spec_dir/vault/$env.yml",         "v");
	}
	write_file("$spec_dir/spec.t",
		"#!perl\nuse Test::More; plan tests => 1; ok 1; done_testing();\n");

	my ($out, $err, $rc) = run_bin(
		args => ['run', '--regenerate',
			 '--focus', 'proto-foo',
			 "$spec_dir/spec.t"],
	);
	ok !-f "$spec_dir/results/proto-foo.yml",       'proto-foo.yml removed';
	ok !-f "$spec_dir/results/proto-foo.yamls.txt", 'proto-foo.yamls.txt removed';
	ok  -f "$spec_dir/vault/proto-foo.yml",
		'proto-foo vault cache untouched (--regenerate does not remove caches)';
	ok  -f "$spec_dir/results/bar.yml",             'non-focused env .yml untouched';
	ok  -f "$spec_dir/results/bar.yamls.txt",       'non-focused env .yamls.txt untouched';
};

subtest '--regenerate-all also removes vault caches for focused envs' => sub {
	my $spec_dir = tempdir(CLEANUP => 1);
	make_path("$spec_dir/results", "$spec_dir/vault");

	for my $env (qw/proto-foo bar/) {
		write_file("$spec_dir/results/$env.yml",       "y");
		write_file("$spec_dir/results/$env.yamls.txt", "t");
		write_file("$spec_dir/vault/$env.yml",         "v");
	}
	write_file("$spec_dir/spec.t",
		"#!perl\nuse Test::More; plan tests => 1; ok 1; done_testing();\n");

	my ($out, $err, $rc) = run_bin(
		args => ['run', '--regenerate-all',
			 '--focus', 'proto-foo',
			 "$spec_dir/spec.t"],
	);
	ok !-f "$spec_dir/results/proto-foo.yml",       'result .yml removed';
	ok !-f "$spec_dir/results/proto-foo.yamls.txt", 'result .yamls.txt removed';
	ok !-f "$spec_dir/vault/proto-foo.yml",         'vault cache removed';
	ok  -f "$spec_dir/results/bar.yml",             'non-focused env .yml untouched';
	ok  -f "$spec_dir/vault/bar.yml",               'non-focused env vault untouched';
};

subtest 'KIT_VALIDATOR_LIB auto-derives from dirname(script)/../lib when unset' => sub {
	my $expect_lib = abs_path("$FindBin::Bin/../lib");
	ok -d $expect_lib, "expected auto-derive target exists ($expect_lib)";

	my $spec_dir = tempdir(CLEANUP => 1);
	write_file("$spec_dir/spec.t", <<'PERL');
#!perl
use Test::More;
plan tests => 1;
print STDERR "KVLIB=", ($ENV{KIT_VALIDATOR_LIB} // ''), "\n";
ok 1;
done_testing();
PERL

	my ($out, $err, $rc) = run_bin(
		args => ['run', "$spec_dir/spec.t"],
		env  => { KIT_VALIDATOR_LIB => undef },
	);
	like $err, qr/KVLIB=\Q$expect_lib\E/,
		"KIT_VALIDATOR_LIB set to $expect_lib when unset";
};

subtest 'auto-derive is silent under installed-mode layout (no Spec.pm in ../lib)' => sub {
	# Simulates: cpanm installs the script to ~/perl5/bin, and ~/perl5/lib
	# exists (local::lib layout) but the Genesis::Kit::Validator modules
	# live at ~/perl5/lib/perl5/, not ~/perl5/lib/ directly.  The naive
	# "does ../lib exist?" heuristic would set KIT_VALIDATOR_LIB to a
	# useless path and cruft up @INC.  Tighten the check by requiring a
	# marker (Genesis/Kit/Validator/Spec.pm) so installed-mode is a no-op.
	my $stage = tempdir(CLEANUP => 1);
	make_path("$stage/bin", "$stage/lib");   # lib dir exists but empty
	require File::Copy;
	File::Copy::copy($BIN, "$stage/bin/genesis-kit-validator")
		or die "copy: $!";
	chmod 0755, "$stage/bin/genesis-kit-validator";

	my $spec_dir = tempdir(CLEANUP => 1);
	write_file("$spec_dir/spec.t", <<'PERL');
#!perl
use Test::More;
plan tests => 1;
print STDERR "KVLIB=", ($ENV{KIT_VALIDATOR_LIB} // ''), "\n";
ok 1;
done_testing();
PERL

	# Run the COPIED bin, not the checkout's.
	my $out_file = File::Temp->new(SUFFIX => '.out');
	my $err_file = File::Temp->new(SUFFIX => '.err');
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if ($pid == 0) {
		delete $ENV{KIT_VALIDATOR_LIB};
		open STDOUT, '>', $out_file->filename or die $!;
		open STDERR, '>', $err_file->filename or die $!;
		exec "$stage/bin/genesis-kit-validator", 'run', "$spec_dir/spec.t";
		die "exec: $!";
	}
	waitpid $pid, 0;
	my $err = do { local (@ARGV, $/) = $err_file->filename; <> } // '';

	like $err, qr/KVLIB=\n/,
		'KIT_VALIDATOR_LIB stays unset when ../lib has no Spec.pm marker';
};

subtest 'explicit KIT_VALIDATOR_LIB env wins over auto-derive' => sub {
	my $spec_dir = tempdir(CLEANUP => 1);
	write_file("$spec_dir/spec.t", <<'PERL');
#!perl
use Test::More;
plan tests => 1;
print STDERR "KVLIB=", ($ENV{KIT_VALIDATOR_LIB} // ''), "\n";
ok 1;
done_testing();
PERL

	my ($out, $err, $rc) = run_bin(
		args => ['run', "$spec_dir/spec.t"],
		env  => { KIT_VALIDATOR_LIB => '/explicit/from/env' },
	);
	like $err, qr{KVLIB=/explicit/from/env},
		'pre-set KIT_VALIDATOR_LIB is preserved (not overridden by auto-derive)';
};

subtest '--genesis CLI flag sets KIT_VALIDATOR_GENESIS for prove' => sub {
	my $spec_dir = tempdir(CLEANUP => 1);
	write_file("$spec_dir/spec.t", <<'PERL');
#!perl
use Test::More;
plan tests => 1;
print STDERR "KVGEN=", ($ENV{KIT_VALIDATOR_GENESIS} // ''), "\n";
ok 1;
done_testing();
PERL

	my ($out, $err, $rc) = run_bin(
		args => ['run', '--genesis', '/some/g32',
			 "$spec_dir/spec.t"],
	);
	like $err, qr{KVGEN=/some/g32}, '--genesis sets KIT_VALIDATOR_GENESIS';
};

subtest '--genesis CLI flag wins over KIT_VALIDATOR_GENESIS env' => sub {
	my $spec_dir = tempdir(CLEANUP => 1);
	write_file("$spec_dir/spec.t", <<'PERL');
#!perl
use Test::More;
plan tests => 1;
print STDERR "KVGEN=", ($ENV{KIT_VALIDATOR_GENESIS} // ''), "\n";
ok 1;
done_testing();
PERL

	my ($out, $err, $rc) = run_bin(
		args => ['run', '--genesis', '/flag/g32',
			 "$spec_dir/spec.t"],
		env  => { KIT_VALIDATOR_GENESIS => '/env/g32' },
	);
	like $err, qr{KVGEN=/flag/g32}, 'flag value takes precedence';
};

subtest '--genesis-lib CLI flag sets GENESIS_LIB (not KIT_VALIDATOR_LIB)' => sub {
	my $spec_dir = tempdir(CLEANUP => 1);
	write_file("$spec_dir/spec.t", <<'PERL');
#!perl
use Test::More;
plan tests => 1;
print STDERR "GLIB=", ($ENV{GENESIS_LIB} // ''), "\n";
print STDERR "KVLIB=", ($ENV{KIT_VALIDATOR_LIB} // ''), "\n";
ok 1;
done_testing();
PERL

	my ($out, $err, $rc) = run_bin(
		args => ['run', '--genesis-lib', '/dev/genesis/checkout/lib',
			 "$spec_dir/spec.t"],
	);
	like $err, qr{GLIB=/dev/genesis/checkout/lib},
		'--genesis-lib sets GENESIS_LIB (Genesis dev-loop lib override)';
	unlike $err, qr{KVLIB=/dev/genesis/checkout/lib},
		'--genesis-lib does NOT set KIT_VALIDATOR_LIB (distinct concept)';
};

subtest '--genesis-lib CLI flag wins over GENESIS_LIB env' => sub {
	my $spec_dir = tempdir(CLEANUP => 1);
	write_file("$spec_dir/spec.t", <<'PERL');
#!perl
use Test::More;
plan tests => 1;
print STDERR "GLIB=", ($ENV{GENESIS_LIB} // ''), "\n";
ok 1;
done_testing();
PERL

	my ($out, $err, $rc) = run_bin(
		args => ['run', '--genesis-lib', '/flag/genesis-lib',
			 "$spec_dir/spec.t"],
		env  => { GENESIS_LIB => '/env/genesis-lib' },
	);
	like $err, qr{GLIB=/flag/genesis-lib}, 'flag value takes precedence';
};

done_testing;
