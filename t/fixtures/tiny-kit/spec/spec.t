#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;

# Load the framework from the parent kit-validator checkout.
use lib "$FindBin::Bin/../../../../lib";

use Kit::Validator qw/kit_dir test_env/;

kit_dir("$FindBin::Bin/..");

test_env(name => 'minimal');
