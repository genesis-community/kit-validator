#!/usr/bin/env perl
package Genesis::Hook::Blueprint::Tiny v0.0.1;

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

sub perform {
	my ($self) = @_;
	$self->add_files('manifests/tiny.yml');
	return $self->done();
}

1;
