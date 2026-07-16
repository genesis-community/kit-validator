#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

# Load the framework from the parent kit-validator checkout.
use lib "$FindBin::Bin/../../../../lib";

use Genesis::Kit::Validator::Spec qw/kit_dir test_env/;
use Test::More;

kit_dir("$FindBin::Bin/..");

test_env(name => 'minimal');

done_testing;
