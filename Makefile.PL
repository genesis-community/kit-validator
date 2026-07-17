use strict;
use warnings;
use ExtUtils::MakeMaker 6.48;

WriteMakefile(
	NAME             => 'Genesis::Kit::Validator',
	AUTHOR           => 'Genesis Community <team@genesisproject.io>',
	VERSION_FROM     => 'lib/Genesis/Kit/Validator.pm',
	ABSTRACT         => 'Perl spec-test framework for Genesis kits',
	LICENSE          => 'mit',
	MIN_PERL_VERSION => '5.20.0',

	CONFIGURE_REQUIRES => {
		'ExtUtils::MakeMaker' => '6.48',
	},

	# Runtime deps beyond perl-base.  Genesis's own Perl lib is
	# resolved at runtime (either via PERL5LIB, ~/.genesis/lib
	# self-extract, or a KIT_VALIDATOR_GENESIS override), so it is
	# NOT listed here -- treating it as a soft dep at load time
	# lets genesis-kit-validator install cleanly on machines that pack
	# Genesis differently.
	PREREQ_PM => {
		'JSON::PP'  => '0',
		'Test::More' => '0.98',
	},

	TEST_REQUIRES => {
		'Test::Deep'   => '0',
		'Test::Output' => '0',
		'Test::Exit'   => '0',
	},

	EXE_FILES => [ 'bin/genesis-kit-validator' ],

	META_MERGE => {
		'meta-spec' => { version => 2 },
		resources   => {
			repository => {
				type => 'git',
				url  => 'https://github.com/genesis-community/genesis-kit-validator.git',
				web  => 'https://github.com/genesis-community/genesis-kit-validator',
			},
			bugtracker => {
				web => 'https://github.com/genesis-community/genesis-kit-validator/issues',
			},
		},
	},

	dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz' },
	clean => { FILES    => 'Genesis-Kit-Validator-*' },
);
