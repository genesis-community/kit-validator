#!/usr/bin/env perl
package Genesis::Hook::Blueprint::Faulty v0.0.1;

use strict;
use warnings;
use v5.20;

BEGIN { push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib' }

use parent qw(Genesis::Hook::Blueprint);
use Genesis qw/bail/;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->{files} = [];
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}

# Each feature maps to one manifests/<feature>.yml carrying exactly one
# deliberate fault.  Keeping the mapping mechanical means a new error
# scenario is a manifest file plus a spec env, with no hook changes.
sub perform {
	my ($self) = @_;
	$self->add_files('manifests/base.yml');
	$self->add_files("manifests/$_.yml") for $self->features;
	return $self->done();
}

1;
