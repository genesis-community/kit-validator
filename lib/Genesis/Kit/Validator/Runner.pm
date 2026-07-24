package Genesis::Kit::Validator::Runner;
use v5.20;
use warnings;
use utf8;

use Genesis::Kit::Validator::Environment;
use Genesis::Kit::Validator::Fixture;
use Genesis::Kit::Validator::Prune;
use Genesis::Kit::Validator::Bootstrap;
use Genesis::Kit::Validator::Runner::Cmd;

use File::Temp qw/tempdir/;
use File::Basename qw/basename/;
use Cwd qw/getcwd/;

# Load Genesis lazily.  Framework unit tests import the Runner but
# should not require the Genesis runtime; only Runner->run does.
my $GENESIS_LOADED;

# _require_genesis - guarantee that Genesis's Perl lib is loadable and
# consistent with the genesis binary that the pipeline will shell out
# to.
#
# Coupling problem this solves: `~/.genesis/lib/` reflects whichever
# genesis binary was last invoked on this box.  If our Perl loads
# Genesis modules from there and then we shell to a *different* genesis
# binary (e.g. via KIT_VALIDATOR_GENESIS pointing at a locally-packed
# g32), that binary re-extracts to the same directory mid-run and we
# end up straddling two versions -- some modules from image A already
# in %INC, some file-system state now reflects image B.
#
# Fix: at load time, peek at the target binary's embedded checksum
# (the first line after __DATA__ in the self-extracting stub) and
# compare against `<genesis_home>/checksum`.  If they match, the
# extract already reflects the binary we intend to test with -- no
# action needed.  If they don't (or the checksum file is absent), run
# `<binary> --version >/dev/null` to force the binary's own extract
# routine; the resulting state is authoritative for our subsequent
# module loads.
#
# Also honors PERL5LIB / an already-visible Genesis on @INC as a
# fallback path -- useful for dev iteration inside the studio, where
# the lib comes from a git checkout, not from a genesis binary extract.
sub _require_genesis {
	return if $GENESIS_LOADED;

	# Dev-loop path: GENESIS_LIB pointing at a genesis source
	# checkout is authoritative -- the same env var `bin/genesis`
	# itself reads to find its Perl modules.  Prepend to @INC so
	# `require Genesis` picks up source before any packed extract
	# that might also be visible.
	if ($ENV{GENESIS_LIB} && -d $ENV{GENESIS_LIB}) {
		require lib;
		lib->import($ENV{GENESIS_LIB});
	}

	# Seed $Genesis::VERSION before require Genesis so its `//=` in
	# `our $VERSION //= "(development)"` doesn't clobber a real
	# value.  Kits gate on this via check_minimum_genesis_version
	# (e.g. bosh/4.1.0 requires >=3.1.0-rc.14); a bare "(development)"
	# never satisfies semver checks.
	_seed_genesis_version();

	# Fast path: if Genesis is already reachable via @INC (dev
	# iteration with PERL5LIB or GENESIS_LIB set), use it -- but
	# only if it loads cleanly.  Any load error falls through to
	# the extract path.
	if (eval { require Genesis; require Service::Vault::Local; 1 }) {
		$GENESIS_LOADED = 1;
		return;
	}
	my $inline_err = $@;

	my $genesis_home = $ENV{GENESIS_HOME} || ($ENV{HOME}//'').'/.genesis';
	my $genesis_lib  = "$genesis_home/lib";
	my $binary       = $ENV{KIT_VALIDATOR_GENESIS} || 'genesis';

	unless (_extract_is_current($binary, $genesis_home)) {
		my $rc = system("$binary --version >/dev/null 2>&1");
		die
			"Genesis::Kit::Validator::Runner: could not invoke '$binary' to prepare "
			."the Genesis Perl lib.\n".
			"Genesis binary exited with status $rc.\n".
			"Either put a genesis binary on PATH, set "
			."KIT_VALIDATOR_GENESIS to point at one, or set PERL5LIB to "
			."include a Genesis checkout's lib/ directory.\n".
			"Inline-load error was: $inline_err\n"
			if $rc != 0;
	}

	die "Genesis::Kit::Validator::Runner: Genesis lib directory not present at "
		."$genesis_lib after invoking '$binary'.\n"
		unless -d $genesis_lib;

	require lib;
	lib->import($genesis_lib);

	eval { require Genesis; require Service::Vault::Local; 1 } or die
		"Genesis::Kit::Validator::Runner: Genesis modules could not be loaded "
		."from $genesis_lib after successful extract.\nUnderlying error: $@\n";
	$GENESIS_LOADED = 1;
}

# _seed_genesis_version - pin $Genesis::VERSION before `require
# Genesis` so kit min-version checks pass in-process.  Preference
# order: GENESIS_DEV_VERSION env var (matches Genesis's own dev
# convention), then a `<binary> --version` probe, then leave unset
# and let Genesis default to "(development)".
sub _seed_genesis_version {
	return if defined $Genesis::VERSION;
	if (my $v = $ENV{GENESIS_DEV_VERSION}) {
		$Genesis::VERSION = $v;
		return;
	}
	my $binary = $ENV{KIT_VALIDATOR_GENESIS} || 'genesis';
	my $out = eval { qx{$binary --version 2>/dev/null} } // '';
	if ($out =~ /Genesis\s+v(\S+)/i) {
		$Genesis::VERSION = $1;
	}
}

# _extract_is_current - probe whether ~/.genesis/checksum matches the
# checksum embedded in the target binary's self-extracting stub.
# Returns 1 when we can safely skip the `<binary> --version` invocation
# because the extract is already the right version; returns 0 on any
# uncertainty (missing files, stub in an unexpected format, etc) --
# the caller then falls through to invoking the binary, which does its
# own more thorough check-and-extract.
sub _extract_is_current {
	my ($binary, $genesis_home) = @_;

	my $checksum_file = "$genesis_home/checksum";
	return 0 unless -f $checksum_file;
	my $have = do {
		open my $fh, '<', $checksum_file or return 0;
		local $/;
		<$fh>;
	};
	return 0 unless defined $have;
	$have =~ s/\s+//g;
	return 0 unless length $have;

	my $binary_path = _resolve_binary_path($binary);
	return 0 unless $binary_path && -f $binary_path;

	# The self-extracting stub is a Perl script with an SHA1 as the
	# first line after `__DATA__`.  If the format ever changes -- or
	# KIT_VALIDATOR_GENESIS points at something entirely non-Perl --
	# this probe returns 0 and we fall through to `<binary> --version`,
	# which is the authoritative check.  Cap the scan at 4KB so we
	# never slurp a large compiled binary looking for a marker that
	# will never appear.
	open my $bfh, '<', $binary_path or return 0;
	my $seen = 0;
	while (my $line = <$bfh>) {
		$seen += length($line);
		if ($seen > 4096) { close $bfh; return 0 }
		chomp $line;
		next unless $line eq '__DATA__';
		my $want = <$bfh>;
		close $bfh;
		return 0 unless defined $want;
		$want =~ s/\s+//g;
		return $want eq $have ? 1 : 0;
	}
	close $bfh;
	return 0;
}

sub _resolve_binary_path {
	my ($name) = @_;
	return $name if $name =~ m{/} && -x $name;
	for my $dir (split /:/, ($ENV{PATH}//'')) {
		next unless length $dir;
		return "$dir/$name" if -x "$dir/$name";
	}
	return undef;
}

# run - orchestrate one environment through the validation pipeline
# and emit a Test::More subtest reporting the outcome.
#
# On the assertion path, this shells out to `genesis manifest` (via
# Genesis::run) for realistic CLI-surface exercise.  On the
# diagnostic path (when a shell-out fails), it uses in-process
# Genesis::Env API calls to explain WHY -- schema errors, missing
# secrets, hook stack traces -- rather than dumping raw stderr.
sub run {
	my ($class, $env, %opts) = @_;

	my $kit_dir = $opts{kit_dir}
		or die "Genesis::Kit::Validator::Runner->run: kit_dir is required\n";

	# Late-load Test::More so the module can be `use`d in contexts that
	# never call ->run (e.g. inline docs, package_loaded checks).
	require Test::More;
	# Emit a visual banner so consecutive envs are easy to distinguish
	# in the scrollback -- Test::More::subtest itself only prints a
	# `# Subtest: env: <name>` header, which reads as continuation
	# rather than a boundary in a busy log stream.
	#
	# Theme flips on the detected terminal background so the bar
	# stays high-contrast on both dark and light schemes:
	#   dark terminal  -> light-grey rules, black-on-white title bar
	#   light terminal -> dark-grey rules, bright-white-on-black bar
	# terminal_colors() defaults to dark when the probe fails.
	require Genesis::Term;
	my $w = Genesis::Term::terminal_width();
	my $tc = Genesis::Term::terminal_colors();
	my $is_dark = $tc ? $tc->{is_dark} : 1;
	# Theme SGR triple:
	#   rule -- horizontal border colour
	#   bar  -- fg+bg of the title line
	#   name -- accent colour applied only to the env name so it
	#           reads as the eye-drawing token on the bar; keeps
	#           the bar's bg so the highlight stays a solid strip.
	my ($rule_sgr, $bar_sgr, $name_sgr) = $is_dark
		? ("\e[90m",     "\e[30;47m", "\e[1;35;47m")  # dark bg: light-grey rules, black-on-white bar, bold magenta name
		: ("\e[30m",     "\e[97;40m", "\e[1;95;40m"); # light bg: dark-grey rules, white-on-black bar, bold bright-magenta name
	my $reset = "\e[0m";
	my $rule  = ('─' x $w);
	my $label = 'Testing environment: ';
	my $name  = $env->name;
	# Compute the padding manually because SGR escapes don't
	# occupy screen columns -- sprintf's %-*s width would count
	# them and misalign the trailing edge of the bar.
	my $pad_len = $w - 2 - length($label) - length($name);
	$pad_len = 0 if $pad_len < 0;
	my $pad = ' ' x $pad_len;
	warn "\n"
	   . "${rule_sgr}${rule}${reset}\n"
	   . "${bar_sgr}  ${label}${name_sgr}${name}\e[22m${bar_sgr}${pad}${reset}\n"
	   . "${rule_sgr}${rule}${reset}\n";
	Test::More::subtest("env: ".$env->name => sub {
		my $ok = eval { $class->_execute($env, kit_dir => $kit_dir); 1 };
		if ($ok) {
			Test::More::pass("pipeline: ".$env->name);
		} else {
			my $err = $@;
			Test::More::fail("pipeline: ".$env->name);
			Test::More::diag($err);
			# Record for `KIT_VALIDATOR_FOCUS=@last-failed` re-runs.
			require Genesis::Kit::Validator;
			Genesis::Kit::Validator::record_failure($env->name);
		}
	});
}

sub _execute {
	my ($class, $env, %opts) = @_;
	_require_genesis();

	# Reject any env name Genesis itself would reject, using
	# Genesis's own validator.  This also blocks path-traversal /
	# shell-metachar injection into the per-env workdir path we're
	# about to build under $ENV{HOME}.
	require Genesis::Env;
	if (my $err = Genesis::Env::_env_name_errors($env->name)) {
		die "Genesis::Kit::Validator::Runner: invalid env name '".$env->name."':\n$err";
	}

	my $kit_dir     = $opts{kit_dir};
	my $kit_name    = _detect_kit_name($kit_dir);
	my $fixture_dir = "$kit_dir/spec";
	my $fx          = Genesis::Kit::Validator::Fixture->new(kit_dir => $kit_dir);

	# 1. Ephemeral per-env workdir as a subdirectory of the
	# run-scoped sandbox HOME (set up by Genesis::Kit::Validator::Spec at
	# load time -- see that module's SANDBOX MODEL section).  HOME
	# itself is not rescoped here; every env in the run shares the
	# same .saferc and .genesis under $ENV{HOME}, which is exactly
	# what the bash-hook sub-genesis calls need to resolve the
	# local vault.
	#
	# The workdir lives under $HOME rather than in a sibling /tmp
	# dir so a single CLEANUP -- Genesis::Kit::Validator::Spec's sandbox
	# tempdir -- handles removal on interpreter exit.  No per-env
	# File::Temp handles racing at exit time.
	my $workdir = tempdir(
		$env->name.'-XXXXXX', DIR => $ENV{HOME}, CLEANUP => 0,
	);
	local our $CURRENT_WORKDIR = $workdir;

	# 2. Shared run-scoped vault owned by Genesis::Kit::Validator::Spec.
	# Each env's writes land under secret/<env-name>/<kit>/..., so the
	# subtree per env is naturally disjoint -- no need to spin up a
	# fresh vault (and pay the safe/vault fork + saferc restore cost)
	# for every env.
	require Genesis::Kit::Validator::Spec;
	my $vault = Genesis::Kit::Validator::Spec::shared_vault()
		or die "Genesis::Kit::Validator::Runner: no shared vault -- ".
			"was Genesis::Kit::Validator::Spec loaded?\n";

	# 3. Testing-mode env vars carried into every genesis subcommand.
	# Git identity comes from GIT_AUTHOR_NAME/EMAIL set once by
	# Genesis::Kit::Validator::Spec at load time -- see that module's
	# SANDBOX MODEL section.
	local %ENV = (%ENV, %{Genesis::Kit::Validator::Runner::Cmd::testing_env(env => $env)});

	# 4. genesis init in the workdir, linking against the kit under test.
	# Pass the vault's URL, not its alias: Service::Vault::Remote->find
	# keys lookup on URL, and passing the alias name produces the opaque
	# "Can't call method 'connect_and_validate' on undef" downstream.
	_run_cmd(
		Genesis::Kit::Validator::Runner::Cmd::genesis_init_cmd(
			kit_name => $kit_name,
			kit_dir  => $kit_dir,
			workdir  => $workdir,
			vault    => $vault->url,
		),
		onfailure => "genesis init failed for ".$env->name,
	);

	# 6. Copy fixture files (env yml, ops yml files).
	_copy_env_fixture($fx, $env, $workdir);
	_copy_ops_fixtures($fx, $env, $workdir);

	# 7. Import exodus stub if present.
	_import_exodus_if_present($fx, $env, $vault);

	# 7b. Seed empty CPI-config stub in the workdir.  Genesis's
	# opportunistic-cpi prefetch (Env::required_configs) auto-appends
	# `cpi` to the required-configs list for the check / manifest /
	# deploy hooks.  Without a value on disk, download_configs will
	# reach for the parent BOSH director -- which the ephemeral
	# workdir never has -- and bail.  Writing an empty `cpis: []`
	# stub and passing it via `-c cpi=<path>` satisfies has_config
	# without touching a director.  Per-env cpi fixtures override
	# via $env->cpi_config.
	my $cpi_stub_path = "$workdir/empty-cpi.yml";
	_write_cpi_stub($cpi_stub_path);

	# 8. Vault-cache bootstrap (only if spec/vault/<env>.yml absent).
	# Expected-failure envs (any output_matchers set) never bootstrap:
	# add-secrets runs the blueprint, and for those envs the bail IS
	# the assertion -- it fires later at the matcher-aware check/
	# manifest steps.
	if (%{$env->output_matchers // {}}) {
		_step($env, "skipping bootstrap (env has output_matchers)");
	} else {
		_bootstrap_vault_cache_if_missing($fx, $env, $kit_name, $vault);
	}

	# 9. Always import the (now-present) tokenized cache back into the
	# vault, replacing the real generated values from bootstrap with
	# the `<!{meta.vault}/...!>` markers that testkit-style specs use.
	# This is what lets golden manifests be committed to git safely --
	# they carry the tokens, not real secret material, and every
	# subsequent smoke run replays the same tokens through spruce.
	_step($env, "importing vault cache into local vault");
	_import_vault_cache($fx, $env, $vault);

	# 10. genesis check with output_matchers awareness.
	_step($env, Genesis::Kit::Validator::Spec::cprintf("running #keyword{genesis check}"));
	my $check_out = _run_genesis_step(
		cmd       => Genesis::Kit::Validator::Runner::Cmd::genesis_check_cmd(
			env => $env, fixture_dir => $fixture_dir,
			cpi_stub_path => $cpi_stub_path),
		matcher   => $env->output_matchers->{genesis_check},
		step_name => 'genesis check',
	);

	# A genesis_check matcher means the env asserts that preflight
	# fails.  _run_genesis_step has already verified the message, so
	# the env's assertion is complete -- and nothing downstream is
	# meaningful, because an operator whose check fails never gets to
	# generate a manifest.  Stop here rather than running `genesis
	# manifest` and materialising a golden for an environment that
	# cannot legitimately produce one.
	if ($env->output_matchers->{genesis_check}) {
		_step($env, "genesis check failed as expected; skipping remaining pipeline");
		return;
	}

	# 11. genesis yamls: capture merge order, diff against golden.
	# Runs as its own subtest so blueprint-order regressions surface
	# separately from manifest-content regressions.
	{
		_step($env, Genesis::Kit::Validator::Spec::cprintf(
			"running #keyword{genesis yamls} (merge-order diff)"));
		_run_yamls_diff_step(
			env         => $env,
			fixture_dir => $fixture_dir,
			cpi_stub_path => $cpi_stub_path,
		);
	}

	# 12. genesis manifest with output_matchers awareness.
	_step($env, Genesis::Kit::Validator::Spec::cprintf("running #keyword{genesis manifest}"));
	my $manifest_yaml = _run_genesis_step(
		cmd       => Genesis::Kit::Validator::Runner::Cmd::genesis_manifest_cmd(
			env => $env, fixture_dir => $fixture_dir,
			cpi_stub_path => $cpi_stub_path),
		matcher   => $env->output_matchers->{genesis_manifest},
		step_name => 'genesis manifest',
		capture   => 1,
	);

	# If the env expected the manifest step to fail on output_matchers,
	# the manifest_yaml is undef; skip the remainder of the pipeline.
	return unless defined $manifest_yaml;

	# 12. Prune volatile keys; peel off bosh-variables.
	# Parse via Genesis::load_yaml (spruce-shell under the hood).
	_step($env, "pruning volatile keys from manifest");
	my $manifest = Genesis::load_yaml($manifest_yaml);
	my $is_proto = _env_has_proto_feature($env, $workdir);
	my ($pruned, $bosh_vars)
		= Genesis::Kit::Validator::Prune::prune_manifest($manifest, {is_proto => $is_proto});

	# 13. Credhub-stub bootstrap.
	_bootstrap_credhub_stub_if_missing($fx, $env, $pruned, $workdir);

	# 14. bosh int interpolation.
	_step($env, Genesis::Kit::Validator::Spec::cprintf("interpolating manifest with #keyword{bosh int}"));
	my $rendered = _interpolate($fx, $env, $pruned, $bosh_vars, $workdir);

	# 15. Golden bootstrap or spruce-diff assertion.
	_step($env, "comparing against golden manifest");
	_compare_or_bootstrap_golden($fx, $env, $rendered);
}

# --------------------------------------------------------------------
# The subroutines below are stubs marking pipeline stages for the
# BOSH-pilot phase.  Each has a defined signature and known behavior
# from testkit; the implementation lands during pilot integration
# testing against real fixtures.

# _run_cmd - splat a Runner::Cmd argv into Genesis::run's calling
# convention.  Genesis::run(prog, @args) auto-wraps the first arg
# as a bash `-c` string and appends `"${@}"` to consume the rest,
# giving us argv-style dispatch.  Extra opts (onfailure, stderr,
# stdin, ...) go in the leading hashref.
# CURRENT_WORKDIR - localized by _execute for the duration of one env
# run.  _run_cmd reads this to default the subprocess cwd, so
# `--cwd deployments/` and other relative paths resolve to the
# per-env subdirectory (which sits inside the run-scoped sandbox HOME
# but is a distinct dir).  Not a stable API -- internal use only.
our $CURRENT_WORKDIR;

sub _run_cmd {
	my ($argv, %opts) = @_;
	die "_run_cmd: expected arrayref argv, got ".ref($argv)."\n"
		unless ref $argv eq 'ARRAY' && @$argv;
	# Force HOME explicitly through the opts.env layer -- Genesis::run
	# has a `local %ENV = %ENV` that inherits from caller, but a
	# subprocess's HOME can otherwise drift if any Genesis::* helper
	# unsets it along the way, and a lost HOME breaks safe/.saferc
	# lookup silently (all_vaults returns []).
	$opts{env} = {%{$opts{env}//{}}, HOME => $ENV{HOME}};
	# Default the subprocess CWD to the per-env workdir (set by
	# _execute), so relative paths like `--cwd deployments/` resolve.
	# Callers may still override via an explicit `dir => ...`.
	$opts{dir} //= ($CURRENT_WORKDIR // $ENV{HOME});
	# Genesis::run captures subprocess pipes without a :utf8 layer,
	# so returns raw bytes.  Downstream Test::More::diag re-emits
	# through a byte-oriented handle that treats each byte as Latin-1
	# and re-encodes -- turning ✓ (E2 9C 93) into `â  ` mojibake.
	# Decode-once here so every caller sees proper character strings.
	require Encode;
	if (wantarray) {
		my ($out, $rc, $err) = Genesis::run(\%opts, @$argv);
		$out = Encode::decode('UTF-8', $out, Encode::FB_DEFAULT()) if defined $out;
		$err = Encode::decode('UTF-8', $err, Encode::FB_DEFAULT()) if defined $err;
		return ($out, $rc, $err);
	}
	my $out = Genesis::run(\%opts, @$argv);
	$out = Encode::decode('UTF-8', $out, Encode::FB_DEFAULT()) if defined $out;
	return $out;
}

# _step - emit a `[TEST <env>] <msg>` progress line on stderr.  Uses
# warn so lines interleave with Test::More output on the same stream
# a real user watches.  Kept tiny -- callers pass a short verb-first
# phrase; details go on their own follow-up lines.
sub _step {
	my ($env, $msg) = @_;
	require Genesis::Kit::Validator::Spec;
	warn Genesis::Kit::Validator::Spec::cprintf(
		"#muted{[}#keyword{TEST} #ident{%s}#muted{]} %s\n",
		$env->name, $msg
	);
}

sub _detect_kit_name {
	my ($kit_dir) = @_;
	# Kits ship a kit.yml at the repo root.  Parse via Genesis's
	# spruce-shell helper -- avoids a hard dep on YAML::PP that
	# Genesis itself has already opted out of.
	my $kit_yml = "$kit_dir/kit.yml";
	die "Genesis::Kit::Validator::Runner: no kit.yml at $kit_yml\n"
		unless -f $kit_yml;
	my $kit = Genesis::load_yaml_file($kit_yml);
	my $name = $kit->{name}
		or die "Genesis::Kit::Validator::Runner: kit.yml has no 'name'\n";
	return $name;
}

# _run_yamls_diff_step - invoke `genesis <env> yamls`, normalize
# the kit-version tokens, and diff against spec/results/<env>.yamls.txt.
# Emits an independent Test::More::subtest so a yamls-order failure
# is visible without the manifest-content diff drowning it out.
#
# Bootstrap: if the golden file doesn't exist, write current
# normalized output to it and pass with a diag() note.  Mirrors
# testkit's createResultIfMissingForManifest behavior -- first run
# generates goldens, subsequent runs enforce them.
sub _run_yamls_diff_step {
	my (%o) = @_;
	my $env = $o{env};
	my $golden_path = "$o{fixture_dir}/results/".$env->name.".yamls.txt";

	require Test::More;
	Test::More::subtest("yamls: ".$env->name => sub {
		my ($out, $rc, $err) = _run_cmd(
			Genesis::Kit::Validator::Runner::Cmd::genesis_yamls_cmd(
				env => $env,
				fixture_dir => $o{fixture_dir},
				cpi_stub_path => $o{cpi_stub_path},
			),
			stderr => 0,
		);
		if ($rc != 0) {
			Test::More::fail("genesis yamls exited with rc=$rc");
			Test::More::diag("stderr:\n$err") if defined $err && length $err;
			return;
		}

		my $actual = _normalize_yamls_output($out);

		if (!-f $golden_path) {
			require File::Path;
			File::Path::make_path("$o{fixture_dir}/results");
			open my $fh, '>', $golden_path
				or die "cannot write $golden_path: $!";
			print $fh $actual;
			close $fh;
			Test::More::pass("bootstrapped golden: ".$env->name.".yamls.txt");
			require Genesis;
			Test::More::diag(
				"wrote new golden: "
				.Genesis::humanize_path($golden_path, base_dir => $o{fixture_dir}."/..")
				." (".length($actual)." bytes)");
			return;
		}

		open my $fh, '<', $golden_path
			or die "cannot read $golden_path: $!";
		my $expected = do { local $/; <$fh> };
		close $fh;

		my $diff = _diff_yamls($actual, $expected);
		if ($diff eq '') {
			Test::More::pass("yamls order matches golden: ".$env->name);
		} else {
			Test::More::fail("yamls order differs from ".$env->name.".yamls.txt");
			Test::More::diag($diff);
		}
	});
}

# _normalize_yamls_output - collapse "<kit>/<version>:" prefixes in
# `genesis <env> yamls` output to "<kit>/<VERSION>:" so a version
# bump of the kit doesn't produce a spurious diff against the
# golden.  Loose match on the version token (anything up to the
# first colon) covers semver, pre-release, and build-metadata
# suffixes (3.2.0-rc.1, 3.2.999-dev, 3.2.0+build.abc).  The
# "     local:" line at the tail has no version and passes through.
sub _normalize_yamls_output {
	my ($text) = @_;
	# Strip ANSI CSI sequences (colors, attributes) first -- genesis
	# emits them on stdout unconditionally, and their bytes would
	# make the golden terminal-dependent.
	$text =~ s/\e\[[0-9;]*m//g;
	$text =~ s{^([^/\s]+)/[^:]+:}{$1/<VERSION>:}mg;
	return $text;
}

# _diff_yamls - unified-diff of two chunks of normalized yamls
# output.  Empty string means identical.  Uses Algorithm::Diff's
# unified formatter with 3 lines of context (standard git diff
# default) so the output is directly readable in a test failure
# report.
sub _diff_yamls {
	my ($actual, $expected) = @_;
	return '' if $actual eq $expected;
	require Algorithm::Diff;
	my @a = split /\n/, $expected, -1;
	my @b = split /\n/, $actual,   -1;
	my $out = "--- expected\n+++ actual\n";
	my $sdiff = Algorithm::Diff::sdiff(\@a, \@b);
	# Group runs into hunks; emit one hunk per contiguous non-'u' run
	# with 3 lines of context on each side.
	my $ctx = 3;
	my ($i, @hunks) = (0);
	while ($i < @$sdiff) {
		if ($sdiff->[$i][0] eq 'u') { $i++; next }
		# Start of a change hunk: back up to include context.
		my $hs = $i - $ctx;  $hs = 0 if $hs < 0;
		# Extend forward: keep going while we see changes or short 'u'
		# runs (< 2*ctx) that would otherwise split into two hunks.
		my $he = $i;
		while ($he + 1 < @$sdiff) {
			$he++;
			if ($sdiff->[$he][0] eq 'u') {
				my $u_run = 0;
				my $probe = $he;
				while ($probe < @$sdiff && $sdiff->[$probe][0] eq 'u') {
					$u_run++; $probe++;
				}
				if ($probe >= @$sdiff || $u_run >= 2 * $ctx) {
					$he += $ctx - 1;
					$he = @$sdiff - 1 if $he >= @$sdiff;
					last;
				}
				$he = $probe - 1;
			}
		}
		push @hunks, [$hs, $he];
		$i = $he + 1;
	}
	for my $h (@hunks) {
		my ($hs, $he) = @$h;
		my ($aln, $bln) = (0, 0);
		my ($astart, $bstart);
		for my $j ($hs .. $he) {
			my $op = $sdiff->[$j][0];
			$aln++ if $op ne '+';
			$bln++ if $op ne '-';
		}
		$astart = 1 + scalar grep { $_->[0] ne '+' } @{$sdiff}[0 .. $hs - 1];
		$bstart = 1 + scalar grep { $_->[0] ne '-' } @{$sdiff}[0 .. $hs - 1];
		$out .= "\@\@ -$astart,$aln +$bstart,$bln \@\@\n";
		for my $j ($hs .. $he) {
			my ($op, $a, $b) = @{$sdiff->[$j]};
			if    ($op eq 'u') { $out .= " $a\n" }
			elsif ($op eq '-') { $out .= "-$a\n" }
			elsif ($op eq '+') { $out .= "+$b\n" }
			elsif ($op eq 'c') { $out .= "-$a\n+$b\n" }
		}
	}
	return $out;
}

sub _copy_env_fixture {
	my ($fx, $env, $workdir) = @_;
	my $src = $fx->path('deployments', $env->name);
	die "spec/deployments/".$env->name.".yml is missing\n" unless -f $src;
	require File::Copy;
	File::Copy::copy($src, "$workdir/deployments/".$env->name.".yml")
		or die "copy failed: $!";
}

sub _copy_ops_fixtures {
	my ($fx, $env, $workdir) = @_;
	return unless @{$env->ops};
	require File::Copy;
	require File::Path;
	File::Path::make_path("$workdir/deployments/ops");
	for my $op (@{$env->ops}) {
		File::Copy::copy(
			$fx->path('ops', $op),
			"$workdir/deployments/ops/$op.yml",
		) or die "copy of ops/$op failed: $!";
	}
}

sub _write_cpi_stub {
	my ($path) = @_;
	open(my $fh, '>', $path)
		or die "kit-validator: cannot write cpi stub $path: $!\n";
	print $fh "---\ncpis: []\n";
	close $fh;
	return $path;
}

sub _import_exodus_if_present {
	my ($fx, $env, $vault) = @_;
	return unless $env->exodus;
	my $stub = $fx->path('exodus', $env->exodus);
	die "spec/exodus/".$env->exodus.".yml is missing (declared by env "
		.$env->name.")\n"
		unless -f $stub;

	# The stub is keyed by service type at the top level; each nested
	# tree becomes flat fields under secret/exodus/<env>/<type>.  Genesis
	# then reads with unflatten() on the far side, so nested paths
	# rejoin transparently.
	#
	# Example:
	#   old-version.yml:  { bosh: { kit_version: 2.3.0 } }
	#   =>  safe set secret/exodus/upgrade/bosh kit_version=2.3.0
	require Genesis;
	my $exodus = Genesis::load_yaml_file($stub);
	die "spec/exodus/".$env->exodus.".yml is not a hash\n"
		unless ref($exodus) eq 'HASH';

	for my $type (keys %$exodus) {
		my $subtree = $exodus->{$type};
		next unless ref($subtree) eq 'HASH';
		my %flat = _flatten_leaves($subtree);
		next unless keys %flat;
		my $path = 'secret/exodus/'.$env->name.'/'.$type;
		# `safe set` accepts key=value pairs positionally.
		_run_cmd(
			['safe', 'set', $path, map { "$_=$flat{$_}" } keys %flat],
			stderr => '&1',
		);
	}
}

# _flatten_leaves - depth-first walk a nested hash, joining keys with
# '.' so the vault entry mirrors what unflatten() expects on the read
# side.  Arrays are stringified as-is; nulls become empty strings.
sub _flatten_leaves {
	my ($tree, $prefix) = @_;
	$prefix //= '';
	my %out;
	for my $key (keys %$tree) {
		my $val = $tree->{$key};
		my $new_key = length($prefix) ? "$prefix.$key" : $key;
		if (ref($val) eq 'HASH') {
			%out = (%out, _flatten_leaves($val, $new_key));
		} else {
			$out{$new_key} = defined($val) ? $val : '';
		}
	}
	return %out;
}

sub _bootstrap_vault_cache_if_missing {
	my ($fx, $env, $kit_name, $vault) = @_;
	require Genesis;
	require Genesis::Kit::Validator::Spec;
	my $cache_path = Genesis::humanize_path(
		$fx->path('vault', $env->name), base_dir => $fx->kit_dir);
	if ($fx->exists('vault', $env->name)) {
		_step($env, Genesis::Kit::Validator::Spec::cprintf(
			"using cached vault at #path{%s}", $cache_path));
		return;
	}
	_step($env, Genesis::Kit::Validator::Spec::cprintf(
		"no cached vault at #path{%s}, regenerating", $cache_path));

	# Ask genesis for the "provided" secret paths that need external
	# seeding (things a real deploy would supply -- IaaS creds, TLS
	# CA overrides, etc.).  Everything else (random passwords, self-
	# signed certs, etc.) genesis will generate via add-secrets.
	# Keep stderr out of the capture -- genesis chatters progress there,
	# and the payload is a pretty-printed JSON array on stdout.
	my $provided_json = _run_cmd(
		Genesis::Kit::Validator::Runner::Cmd::genesis_provided_secrets_cmd(env => $env),
		stderr => 0,
	);
	my ($json_text) = (($provided_json // '') =~ /(\[.*\])/s);
	my $provided = $json_text ? eval { Genesis::load_json($json_text) } : undef;
	$provided = [] unless ref($provided) eq 'ARRAY';
	_step($env, Genesis::Kit::Validator::Spec::cprintf(
		"#number{%d} user-provided secret(s)", scalar(@$provided)));
	for my $entry (@$provided) {
		next unless !ref($entry) && $entry =~ m{^/?(secret/\S+?):(\S+)$};
		my ($path, $key) = ($1, $2);
		# Value tags the secret's full identity, so any downstream
		# transposition surfaces as a visible mismatch.
		my $value = "User<$entry>";
		_run_cmd(['safe', 'set', $path, "$key=$value"], stderr => '&1');
		_step($env, Genesis::Kit::Validator::Spec::cprintf(
			"  #path{%s} -> %s", $entry, $value));
	}

	# add-secrets generates every non-provided secret.
	_step($env, Genesis::Kit::Validator::Spec::cprintf(
		"generating remaining secrets via #keyword{genesis add-secrets}"));
	_run_cmd(
		Genesis::Kit::Validator::Runner::Cmd::genesis_add_secrets_cmd(env => $env),
		onfailure => "genesis add-secrets failed for ".$env->name,
	);

	# Export everything under secret/<env-with-slashes>/<kit>/ and
	# tokenize the leaves to `<!{meta.vault}/<sub>:<key>!>`.
	_step($env, "exporting vault subtree to build cache");
	my $vault_base = Genesis::Kit::Validator::Bootstrap::env_vault_base(
		$env->name, $kit_name);
	my $export_json = _run_cmd(
		['safe', 'export', $vault_base],
		stderr => '&1',
	);
	# safe export emits JSON keyed by full vault path with {key=>value}
	# leaves.  Empty on no matches.
	require Genesis;
	my $export = Genesis::load_json($export_json // '{}');
	$export = {} unless ref($export) eq 'HASH';
	my $tokenized = Genesis::Kit::Validator::Bootstrap::tokenize_vault_export(
		$export,
		env_name => $env->name,
		kit_name => $kit_name,
	);
	# Write to spec/vault/<env>.yml via Genesis::to_yaml (which shells
	# through spruce for consistent output).
	_step($env, Genesis::Kit::Validator::Spec::cprintf(
		"writing vault cache to #path{%s}", $cache_path));
	my $body = Genesis::to_yaml($tokenized);
	$fx->write('vault', $env->name, $body);
}

sub _import_vault_cache {
	my ($fx, $env, $vault) = @_;
	return unless $fx->exists('vault', $env->name);
	# safe import reads JSON from stdin; our spec/vault/<env>.yml is
	# YAML.  Roundtrip via load_yaml + JSON::PP to feed safe.
	require Genesis;
	require JSON::PP;
	my $data = Genesis::load_yaml_file($fx->path('vault', $env->name)) || {};
	my $json = JSON::PP->new->allow_nonref->encode($data);
	_run_cmd(['safe', 'import'], stderr => '&1', stdin => $json);
}

sub _run_genesis_step {
	my (%o) = @_;
	my $cmd       = $o{cmd}       or die "_run_genesis_step: cmd required\n";
	my $step_name = $o{step_name} or die "_run_genesis_step: step_name required\n";
	my $matcher   = $o{matcher};
	my $capture   = $o{capture};

	# Route through _run_cmd for HOME/dir plumbing.  Capture stdout
	# and stderr separately -- stderr => 0 tells Genesis::run to
	# collect stderr into a scratch file and return it as the third
	# tuple element in list context.  This matters for genesis
	# manifest, whose stdout IS the YAML we want to feed to Prune;
	# merging stderr would corrupt the manifest with progress
	# banners like `[env/kit] determining manifest fragments...`.
	my ($out, $rc, $err) = _run_cmd($cmd, stderr => 0);
	$out //= '';
	$err //= '';
	my $combined = $out . ($err ? "\n$err" : '');

	if ($matcher) {
		# output_matchers case: env expects the subcommand to fail (or
		# succeed) with a specific message.  Regex-match the combined
		# stream; non-zero rc is tolerated when the matcher fires.
		if ($combined =~ $matcher) {
			# Pattern matched -- this env's assertion is satisfied at
			# the CLI-output layer, not at the manifest-diff layer.
			# Return undef so the caller short-circuits the remainder
			# of the pipeline (prune/interpolate/diff).
			return;
		}
		die "$step_name: output_matcher did not match.\n".
		    "Pattern: $matcher\n".
		    "Output:\n$combined\n";
	}

	# No matcher: expect a clean exit.
	if ($rc) {
		die "$step_name failed (rc=$rc):\n$combined\n";
	}
	# Capture returns stdout only -- callers that want the manifest
	# YAML need it uncontaminated by progress banners.
	return $capture ? $out : undef;
}

sub _env_has_proto_feature {
	my ($env, $workdir) = @_;
	# The env yml has already been copied into $workdir/deployments/
	# by _copy_env_fixture (step 6); read it back to decide whether
	# to preserve create-env-shaped top-level keys during Prune.
	require Genesis;
	my $path = "$workdir/deployments/".$env->name.".yml";
	return 0 unless -f $path;
	my $spec = eval { Genesis::load_yaml_file($path) };
	return 0 unless ref($spec) eq 'HASH';
	my $features = $spec->{kit}{features} // [];
	return 0 unless ref($features) eq 'ARRAY';
	return (grep { defined && $_ eq 'proto' } @$features) ? 1 : 0;
}

sub _bootstrap_credhub_stub_if_missing {
	my ($fx, $env, $manifest, $workdir) = @_;
	return if $fx->exists('credhub', $env->name);

	# Only fires when the manifest actually declares credhub-style
	# variables.  Skip cleanly when the block is empty or absent so
	# we don't leave dead git noise around for envs that don't use
	# credhub at all.
	my $vars = $manifest->{variables};
	return unless ref($vars) eq 'ARRAY' && @$vars;

	# Write the *pruned* manifest to a scratch file.  Matching testkit:
	# any variable that references a pruned top-level (meta, params,
	# pipeline, ...) legitimately fails here, which is the framework
	# surfacing "this env is coupling to something a real deploy
	# wouldn't have" -- a bug worth catching.
	require Genesis;
	my $mpath = "$workdir/kv-credhub-manifest.yml";
	open my $fh, '>', $mpath or die "cannot write $mpath: $!";
	print $fh Genesis::to_yaml($manifest);
	close $fh;

	# Ask bosh to generate values into a fresh vars-store.  This is
	# purely client-side: bosh walks the variables: block and
	# synthesizes certs/passwords locally.  No director contact.
	my $store_path = "$workdir/kv-credhub-store.yml";
	_run_cmd(
		['bosh', 'int', $mpath, '--vars-store', $store_path],
		stderr => 0,
		onfailure => "bosh int --vars-store failed while bootstrapping "
			.$env->name."'s credhub stub",
	);

	# Read the generated store and tokenize each variable.  Scalars
	# become <!{credhub}:<var>!>; hash-shaped variables (typical for
	# certificates: {ca, certificate, private_key}) expand to
	# <!{credhub}:<var>.<subkey>!> per subkey.  Bootstrap has this.
	my $store = Genesis::load_yaml_file($store_path) || {};
	return unless ref($store) eq 'HASH' && keys %$store;
	my $tokenized = Genesis::Kit::Validator::Bootstrap::tokenize_credhub_vars($store);
	$fx->write('credhub', $env->name, Genesis::to_yaml($tokenized));
}

sub _interpolate {
	my ($fx, $env, $manifest, $bosh_vars, $workdir) = @_;

	# Write $manifest and $bosh_vars to scratch files, then shell to
	# `bosh int` with --vars-file each of them plus any credhub bits.
	# Returns the rendered YAML text.
	require Genesis;
	my $manifest_yaml = Genesis::to_yaml($manifest);
	my $vars_yaml     = Genesis::to_yaml($bosh_vars // {});

	my $mpath = "$workdir/kv-manifest.yml";
	my $vpath = "$workdir/kv-bosh-vars.yml";
	open my $mfh, '>', $mpath or die "cannot write $mpath: $!";
	print $mfh $manifest_yaml;
	close $mfh;
	open my $vfh, '>', $vpath or die "cannot write $vpath: $!";
	print $vfh $vars_yaml;
	close $vfh;

	# Optional credhub_variables (per-env literal overrides) and the
	# credhub stub (tokenized).  Both are threaded into `bosh int` as
	# additional --vars-file entries in the same order testkit uses.
	my (@credhub_vars, @credhub_stub);
	if (my $cv = $env->credhub_vars) {
		if ($fx->exists('credhub_variables', $cv)) {
			@credhub_vars = ($fx->path('credhub_variables', $cv));
		}
	}
	if ($fx->exists('credhub', $env->name)) {
		@credhub_stub = ($fx->path('credhub', $env->name));
	}

	my $cmd = Genesis::Kit::Validator::Runner::Cmd::bosh_int_cmd(
		manifest_path      => $mpath,
		bosh_vars_path     => $vpath,
		credhub_vars_path  => $credhub_vars[0],
		credhub_stub_path  => $credhub_stub[0],
	);
	my ($out, $rc, $err) = _run_cmd($cmd, stderr => 0);
	if ($rc) {
		die "bosh int failed (rc=$rc):\n$out\n$err\n";
	}
	return $out;
}

sub _compare_or_bootstrap_golden {
	my ($fx, $env, $rendered) = @_;
	if (!$fx->exists('results', $env->name)) {
		# First run: materialize the golden and pass silently.
		# Parity with testkit's createResultIfMissingForManifest.
		$fx->write('results', $env->name, $rendered);
		return;
	}

	# Write the rendered manifest to a temp path so spruce diff can
	# see it as a file (spruce reads from paths, not stdin).
	require File::Temp;
	my ($fh, $actual) = File::Temp::tempfile(
		'kv-actual-XXXXXX', SUFFIX => '.yml',
		DIR => File::Spec->tmpdir, UNLINK => 1,
	);
	print $fh $rendered;
	close $fh;

	my $golden = $fx->path('results', $env->name);
	my ($out, $rc, $err) = _run_cmd(
		Genesis::Kit::Validator::Runner::Cmd::spruce_diff_cmd(
			golden_path => $golden,
			actual_path => $actual,
		),
		stderr => 0,
	);
	# spruce diff exit codes:
	#   0 = no changes
	#   1 = differences (real diff to report)
	#   >1 = tool error (bad YAML, missing file, etc.)
	return if ($rc // 0) == 0;

	# Strip ANSI when the test harness isn't a TTY -- CI logs already
	# stripped, but `prove` locally can be either.
	my $diff = defined($out) ? $out : '';
	$diff .= "\n$err" if $err;
	unless (-t STDOUT) {
		$diff =~ s/\e\[[0-9;]*m//g;
	}
	die "manifest differs from spec/results/".$env->name.".yml:\n$diff\n";
}

1;

__END__

=head1 NAME

Genesis::Kit::Validator::Runner - Per-environment orchestrator

=head1 SYNOPSIS

  use Genesis::Kit::Validator::Runner;
  Genesis::Kit::Validator::Runner->run($env, kit_dir => '.');

=head1 DESCRIPTION

Drives one environment through the 15-stage pipeline that mirrors the
Go testkit's C<Test()> behavior.  Emits a Test::More subtest reporting
pass or fail; failure diagnostics include diagnostics gathered
in-process via C<Genesis::Env> (not raw stderr).

=head1 RUNTIME REQUIREMENTS

C<Genesis> and C<Service::Vault::Local> must be loadable.  On kit CI
images this is already the case.  Locally, set C<PERL5LIB> to include
the Genesis checkout's C<lib/> directory.

=head1 STAGE COMPLETION

As of this commit, the orchestrator's outer skeleton, workdir + vault
setup, fixture copying, prune stage, and golden-bootstrap-when-absent
are wired.  The following stages are stubbed and will be filled in
during BOSH-pilot integration work:

=over 4

=item * C<_import_exodus_if_present>

=item * C<_bootstrap_vault_cache_if_missing>

=item * C<_import_vault_cache>

=item * C<_run_genesis_step> (the shell-out to genesis check / manifest)

=item * C<_env_has_proto_feature>

=item * C<_bootstrap_credhub_stub_if_missing>

=item * C<_interpolate>

=item * C<_compare_or_bootstrap_golden> (compare arm; bootstrap arm is done)

=back

=cut
