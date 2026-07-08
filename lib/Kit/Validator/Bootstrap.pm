package Kit::Validator::Bootstrap;
use v5.20;
use warnings;
use Storable qw/dclone/;

# env_vault_base - map ($env_name, $kit_name) to the vault path root
# for that env.  Env-name segments joined by '-' become path segments
# joined by '/', then the kit name is appended.  Genesis convention.
#
#   env=aws,          kit=bosh -> secret/aws/bosh
#   env=us-east-prod, kit=bosh -> secret/us/east/prod/bosh
sub env_vault_base {
	my ($env_name, $kit_name) = @_;
	(my $env_slashed = $env_name) =~ tr{-}{/};
	return "secret/$env_slashed/$kit_name";
}

# tokenize_vault_export - replace every leaf value in a safe-export
# hash with a symbolic `<!{meta.vault}/<subpath>:<key>!>` marker.
# <subpath> is the full vault path with the env-base prefix stripped.
# Paths outside the env base are left alone (defensive; the runner
# should have scoped the export to secret/<env>/<kit>/... but a stray
# entry shouldn't blow up here).
sub tokenize_vault_export {
	my ($export, %opts) = @_;
	my $base = env_vault_base($opts{env_name}, $opts{kit_name});
	my $out = dclone($export);
	for my $path (keys %$out) {
		next unless $path =~ m{^\Q$base\E/(.+)$};
		my $subpath = $1;
		my $entry = $out->{$path};
		next unless ref $entry eq 'HASH';
		for my $key (keys %$entry) {
			$entry->{$key} = "<!{meta.vault}/$subpath:$key!>";
		}
	}
	return $out;
}

# tokenize_credhub_vars - replace every leaf value in a bosh
# vars-store hash with a `<!{credhub}:<var>[.<subkey>]!>` marker.
# Scalars flatten to `<!{credhub}:<var>!>`; hashes expand to
# `<!{credhub}:<var>.<subkey>!>` per entry.  Only one level of
# nesting is expected (matches every credhub stub in the tree).
sub tokenize_credhub_vars {
	my ($vars) = @_;
	my $out = dclone($vars);
	for my $name (keys %$out) {
		my $v = $out->{$name};
		if (ref $v eq 'HASH') {
			for my $sub (keys %$v) {
				$v->{$sub} = "<!{credhub}:$name.$sub!>";
			}
		} else {
			$out->{$name} = "<!{credhub}:$name!>";
		}
	}
	return $out;
}

1;

__END__

=head1 NAME

Kit::Validator::Bootstrap - Tokenize raw exports for spec/vault + spec/credhub stubs

=head1 SYNOPSIS

  use Kit::Validator::Bootstrap;

  my $vault_stub = Kit::Validator::Bootstrap::tokenize_vault_export(
      $safe_export_hash,
      env_name => 'aws',
      kit_name => 'bosh',
  );

  my $credhub_stub = Kit::Validator::Bootstrap::tokenize_credhub_vars(
      $bosh_vars_store_hash,
  );

=head1 DESCRIPTION

Pure functions that produce the C<E<lt>!{meta.vault}/...!E<gt>> and
C<E<lt>!{credhub}:...!E<gt>> tokenized YAML that Genesis kits commit
under C<spec/vault/E<lt>envE<gt>.yml> and C<spec/credhub/E<lt>envE<gt>.yml>.

These stubs replace real generated secrets with symbolic references
so the fixture files are safe to commit; the runner re-imports them
into an ephemeral vault (or bosh vars-store) at test time.

=cut
