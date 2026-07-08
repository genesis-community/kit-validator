package Kit::Validator::Fixture;
use v5.20;
use warnings;

use File::Basename qw/dirname/;
use File::Path qw/make_path/;

sub new {
	my ($class, %opts) = @_;
	my $kit_dir = $opts{kit_dir};
	die "Kit::Validator::Fixture: kit_dir is required\n"
		unless defined $kit_dir && length $kit_dir;
	die "Kit::Validator::Fixture: kit_dir does not exist: $kit_dir\n"
		unless -d $kit_dir;
	return bless {kit_dir => $kit_dir}, $class;
}

sub kit_dir { $_[0]{kit_dir} }

sub path {
	my ($self, $category, $name) = @_;
	return "$self->{kit_dir}/spec/$category/$name.yml";
}

sub exists {
	my ($self, $category, $name) = @_;
	return -f $self->path($category, $name) ? 1 : 0;
}

sub read {
	my ($self, $category, $name) = @_;
	my $p = $self->path($category, $name);
	open my $fh, '<', $p
		or die "Kit::Validator::Fixture: cannot read $p: $!\n";
	local $/;
	my $body = <$fh>;
	close $fh;
	return $body;
}

sub write {
	my ($self, $category, $name, $body) = @_;
	my $p = $self->path($category, $name);
	my $dir = dirname($p);
	make_path($dir) unless -d $dir;
	open my $fh, '>', $p
		or die "Kit::Validator::Fixture: cannot write $p: $!\n";
	print $fh $body;
	close $fh;
	return $p;
}

1;

__END__

=head1 NAME

Kit::Validator::Fixture - Path resolution for kit spec fixtures

=head1 SYNOPSIS

  my $fx = Kit::Validator::Fixture->new(kit_dir => '/path/to/kit');
  my $p  = $fx->path('deployments', 'aws');   # kit/spec/deployments/aws.yml
  if ($fx->exists('vault', 'aws')) { ... }
  my $body = $fx->read('deployments', 'aws');
  $fx->write('credhub', 'aws', $rendered);

=head1 DESCRIPTION

Constructs and manipulates C<E<lt>kit_dirE<gt>/spec/E<lt>categoryE<gt>/E<lt>nameE<gt>.yml>
paths.  Does not interpret content beyond raw slurp / raw write --
YAML parsing happens in the caller.

=cut
