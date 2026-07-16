package Genesis::Kit::Validator::Runner::Cmd;
use v5.20;
use warnings;

# Pure command builders.  Each sub returns an arrayref suitable for
# passing to Genesis::run or system() -- no shell interpolation, no
# side effects.  Parity anchor: testkit/testing/{genesis,bosh}.go.

# _genesis_bin - the argv[0] for every genesis-* subcommand.  Kit CI
# uses `genesis` off PATH; local dev can point at an alternate binary
# (e.g. a hand-packed g32) via KIT_VALIDATOR_GENESIS.
sub _genesis_bin {
	return $ENV{KIT_VALIDATOR_GENESIS} || 'genesis';
}

sub _config_flags {
	my ($env, $fixture_dir, $cpi_stub_path) = @_;
	my @flags;
	if (defined(my $cc = $env->cloud_config)) {
		push @flags, '-c', "cloud=$fixture_dir/cloud_configs/$cc.yml";
	}
	if (defined(my $rc = $env->runtime_config)) {
		push @flags, '-c', "runtime=$fixture_dir/runtime_configs/$rc.yml";
	}
	# CPI config: Genesis's opportunistic prefetch (Env::required_configs)
	# auto-appends `cpi` to the required-configs list for the check /
	# manifest / deploy hooks.  Without a value on disk, the resulting
	# `download_configs` call reaches for the parent BOSH director --
	# which kit-validator's ephemeral workdir never has.  Supply either
	# the env's opted-in cpi fixture or an empty stub written by the
	# Runner into the workdir.
	if (defined(my $ci = $env->cpi_config)) {
		push @flags, '-c', "cpi=$fixture_dir/cpi_configs/$ci.yml";
	} elsif (defined $cpi_stub_path) {
		push @flags, '-c', "cpi=$cpi_stub_path";
	}
	return @flags;
}

sub genesis_init_cmd {
	my (%o) = @_;
	return [
		_genesis_bin(), 'init',
		'--link-dev-kit', $o{kit_dir},
		'--vault',        $o{vault},
		'--cwd',          $o{workdir},
		'--directory',    'deployments',
		$o{kit_name},
	];
}

sub genesis_check_cmd {
	my (%o) = @_;
	my $env = $o{env};
	return [
		_genesis_bin(), 'check',
		'--cwd', 'deployments/',
		'--no-manifest',
		'--no-stemcells',
		_config_flags($env, $o{fixture_dir}, $o{cpi_stub_path}),
		$env->name,
	];
}

sub genesis_manifest_cmd {
	my (%o) = @_;
	my $env = $o{env};
	return [
		_genesis_bin(), 'deployments/'.$env->name, 'manifest',
		'--type=unredacted',
		_config_flags($env, $o{fixture_dir}, $o{cpi_stub_path}),
	];
}

sub genesis_yamls_cmd {
	my (%o) = @_;
	my $env = $o{env};
	return [
		_genesis_bin(), 'deployments/'.$env->name, 'yamls',
		_config_flags($env, $o{fixture_dir}, $o{cpi_stub_path}),
	];
}

sub genesis_check_secrets_cmd {
	my (%o) = @_;
	return [
		_genesis_bin(), 'check-secrets',
		'--no-color', '-lm', '-v',
		'--cwd', 'deployments/',
		$o{env}->name,
		'type=provided',
	];
}

sub genesis_add_secrets_cmd {
	my (%o) = @_;
	return [
		_genesis_bin(), 'add-secrets',
		'--cwd', 'deployments/',
		$o{env}->name,
	];
}

sub bosh_int_cmd {
	my (%o) = @_;
	my @cmd = (
		'bosh', 'int',
		$o{manifest_path},
		'--var-errs',
		'--var-errs-unused',
		'--vars-file', $o{bosh_vars_path},
	);
	push @cmd, '--vars-file', $o{credhub_vars_path} if $o{credhub_vars_path};
	push @cmd, '--vars-file', $o{credhub_stub_path} if $o{credhub_stub_path};
	return \@cmd;
}

sub spruce_diff_cmd {
	my (%o) = @_;
	return ['spruce', 'diff', $o{golden_path}, $o{actual_path}];
}

sub testing_env {
	my (%o) = @_;
	my $env = $o{env};
	return {
		GENESIS_TESTING_BOSH_CPI                    => $env->cpi,
		GENESIS_TESTING_CHECK_SECRETS_PRESENCE_ONLY => 'true',
		GENESIS_TESTING                             => 'yes',
		GENESIS_BOSH_VERIFIED                       => $env->name,
	};
}

1;

__END__

=head1 NAME

Genesis::Kit::Validator::Runner::Cmd - Pure command builders for the runner

=head1 SYNOPSIS

  use Genesis::Kit::Validator::Runner::Cmd;

  my $cmd = Genesis::Kit::Validator::Runner::Cmd::genesis_check_cmd(
      env         => $env,
      fixture_dir => '/kits/bosh/spec',
  );
  Genesis::run($cmd);   # or system(@$cmd)

=head1 DESCRIPTION

Each function returns an arrayref (or a plain hashref, for
C<testing_env>) with no side effects.  The Runner uses these to
build the argv/env-var lists for each subprocess call; tests can
assert the arg list is right without ever invoking a real
C<genesis> or C<bosh> binary.

Parity target: C<testkit/testing/{genesis,bosh}.go>.

=cut
