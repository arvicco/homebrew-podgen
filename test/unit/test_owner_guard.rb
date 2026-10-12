# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "cli"
require "cli/generate_options"

# Probe table for the owner guard in lib/cli.rb (CLAUDE.md golden rule 3).
# Every verdict below was written by hand from what the REAL command would
# do with that argv, before the guard was made to answer it. The guard dry-
# parses generate's argv with generate's own option list, so the verdicts for
# generate hold by construction rather than by token-shape prediction.
class TestOwnerGuard < Minitest::Test
  REFUSAL = "podgen: '%s' is an owner action; refusing inside a Claude Code session (PODGEN_OWNER=1 overrides)\n"

  # [global options, command, command argv, refused inside Claude Code?]
  PROBES = [
    # --- generate: upload flags, abbreviations, completions ---
    [{}, "generate", %w[pod], false],
    [{}, "generate", %w[pod --force], false],
    [{}, "generate", %w[pod --youtube], true],
    [{}, "generate", %w[--youtube pod], true],
    [{}, "generate", %w[pod --you], true],
    [{}, "generate", %w[pod --y], true],
    [{}, "generate", %w[pod --Y], true],
    [{}, "generate", %w[pod --YOU], true],
    [{}, "generate", %w[pod -y], true],
    [{}, "generate", %w[pod -Y], true],
    [{}, "generate", %w[pod -l], true],
    [{}, "generate", %w[pod -yl], true],
    [{}, "generate", %w[pod --lingq], true],
    [{}, "generate", %w[pod --lin], true],
    [{}, "generate", %w[pod --l], true],
    [{}, "generate", %w[--lin pod], true],
    [{}, "generate", %w[pod --force --lin], true],
    # --- generate: value-taking options swallow the next token ---
    [{}, "generate", %w[pod --title -- --you], true],      # title is "--", --you is parsed
    [{}, "generate", %w[pod --image -- --youtube], true],  # image is "--"
    [{}, "generate", %w[pod --title --you], false],        # title is "--you"
    [{}, "generate", %w[pod --rss --lin], false],          # rss is "--lin"
    [{}, "generate", %w[pod --title=--you], false],
    [{}, "generate", %w[pod --title x --youtube], true],
    # --- generate: a real terminator makes the rest positional ---
    [{}, "generate", %w[pod -- --youtube], false],
    [{}, "generate", %w[pod -- -y], false],
    [{}, "generate", %w[pod --url x -- -y], false],
    [{}, "generate", %w[pod --include a,b -- --lingq], false],
    [{}, "generate", %w[pod --lin -- x], true],
    # --- generate: argv the real parser rejects -> conservative token scan ---
    [{}, "generate", %w[pod --no-youtube], false],
    [{}, "generate", %w[pod --youtuber], false],
    [{}, "generate", %w[pod --yes], false],
    [{}, "generate", %w[pod --lang you], false],
    [{}, "generate", %w[pod -f], false],
    [{}, "generate", %w[pod --bogus], false],
    [{}, "generate", %w[pod --bogus --youtube], true],
    [{}, "generate", %w[pod --date nope --youtube], true],
    [{}, "generate", %w[pod --skip abc -y], true],
    [{}, "generate", %w[pod --snip zz --lin], true],
    [{}, "generate", %w[pod --you=1], true],
    [{}, "generate", %w[pod --LIN=x], true],
    [{}, "generate", %w[pod --date nope -- --you], true],   # scan covers tokens after --
    [{}, "generate", %w[pod --help --youtube], true],
    # --- generate: dry-run (global flag or generate's own --dry-run) ---
    [{dry_run: true}, "generate", %w[pod --youtube], false],
    [{}, "generate", %w[pod --dry-run --youtube], false],
    [{}, "generate", %w[pod --youtube --dry-run], false],
    [{}, "generate", %w[pod --youtube --dry], false],
    [{}, "generate", %w[pod --title --dry-run --youtube], true],  # title is "--dry-run"
    [{}, "generate", %w[pod --youtube --include --dry-run], true],
    [{}, "generate", %w[pod --date nope --dry-run --youtube], true], # unparseable: no exemption
    # --- generate: global --lingq ---
    [{lingq: true}, "generate", %w[pod], true],
    [{lingq: true, dry_run: true}, "generate", %w[pod], false],
    # --- publish / unpublish / tweet honour dry-run ---
    [{}, "publish", %w[pod], true],
    [{}, "publish", %w[pod --dry-run], false],
    [{}, "publish", %w[--dry-run pod], false],
    [{}, "publish", %w[pod --date=2026-01-01 --dry-run], false],
    [{}, "publish", %w[pod --date --dry-run], true],
    [{}, "publish", %w[pod --dry], true],
    [{}, "publish", %w[pod -- --dry-run], true],
    [{dry_run: true}, "publish", %w[pod], false],
    [{}, "unpublish", %w[pod], true],
    [{dry_run: true}, "unpublish", %w[pod], false],
    [{}, "tweet", %w[pod ep], true],
    [{}, "tweet", %w[pod ep --dry-run], false],
    [{}, "tweet", %w[pod ep --template --dry-run], true],
    [{dry_run: true}, "tweet", %w[pod ep], false],
    # --- uploads / schedule / analytics ignore dry-run: never exempt ---
    [{dry_run: true}, "uploads", %w[pod], true],
    [{}, "uploads", %w[pod --dry-run], true],
    [{dry_run: true}, "schedule", %w[pod], true],
    [{}, "schedule", %w[pod --dry-run], true],
    [{dry_run: true}, "analytics", %w[deploy], true],
    [{}, "analytics", %w[deploy --dry-run], true],
    # --- non-owner commands: upload-looking flags are not owner flags ---
    [{}, "rss", %w[pod --youtube], false],
    [{}, "regen", %w[pod --lin], false],
    [{lingq: true}, "regen", %w[pod --lingq], false]
  ].freeze

  def setup
    @tmpdir = Dir.mktmpdir("podgen_owner_guard")
    FileUtils.mkdir_p(File.join(@tmpdir, "podcasts", "test_pod"))
    File.write(File.join(@tmpdir, "podcasts", "test_pod", "guidelines.md"), "## Podcast\n- name: Test Pod\n")
    ENV["PODGEN_ROOT"] = @tmpdir
    ENV["CLAUDECODE"] = "1"
    ENV.delete("PODGEN_OWNER")
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    ENV.delete("CLAUDECODE")
    ENV.delete("PODGEN_OWNER")
    FileUtils.rm_rf(@tmpdir)
  end

  class FakeCommand
    def initialize(*) = nil
    def run = 0
  end

  def test_probe_table_has_at_least_forty_rows
    assert_operator PROBES.size, :>=, 40
  end

  def test_refuse_owner_action_matches_every_probe
    failures = PROBES.filter_map do |globals, cmd, argv, refused|
      got = PodgenCLI.refuse_owner_action?(cmd, argv.dup, globals.dup)
      "#{label(globals, cmd, argv)}: expected #{refused}, got #{got}" unless got == refused
    end

    assert_empty failures
  end

  def test_refuse_owner_action_leaves_argv_and_options_untouched
    argv = %w[pod --title -- --you]
    options = {verbosity: :normal}
    PodgenCLI.refuse_owner_action?("generate", argv, options)

    assert_equal %w[pod --title -- --you], argv
    assert_equal({verbosity: :normal}, options)
  end

  # owner_action? for generate is exactly "what the real parser would set".
  def test_owner_action_generate_equals_dry_parse_or_fallback_scan
    PROBES.each do |globals, cmd, argv, _|
      next unless cmd == "generate"

      parsed = PodgenCLI::GenerateOptions.dry_parse(argv)
      expected = if parsed
        !!(globals[:lingq] || parsed[:youtube] || parsed[:lingq])
      else
        !!(globals[:lingq] || argv.any? { PodgenCLI.owner_flag?(it) })
      end

      assert_equal expected, !!PodgenCLI.owner_action?("generate", argv.dup, globals.dup), label(globals, cmd, argv)
    end
  end

  def test_dry_parse_reads_option_values_like_the_real_parser
    assert_equal "--you", PodgenCLI::GenerateOptions.dry_parse(%w[pod --title --you])[:title]
    assert_nil PodgenCLI::GenerateOptions.dry_parse(%w[pod --title --you])[:youtube]
    assert_equal "--", PodgenCLI::GenerateOptions.dry_parse(%w[pod --title -- --you])[:title]
    assert PodgenCLI::GenerateOptions.dry_parse(%w[pod --title -- --you])[:youtube]
  end

  def test_dry_parse_terminator_leaves_rest_positional
    # OptionParser never sets a flag that follows a real `--`; the real
    # command then rejects the leftover argument without uploading anything.
    parsed = PodgenCLI::GenerateOptions.dry_parse(%w[pod -- --youtube])

    refute_nil parsed
    assert_nil parsed[:youtube]
  end

  def test_dry_parse_returns_nil_when_the_real_parser_would_fail
    [
      %w[pod --no-youtube], %w[pod --bogus], %w[pod --date nope], %w[pod --skip abc],
      %w[pod --snip zz], %w[pod --you=1], %w[pod -f], %w[pod --help], %w[pod --version]
    ].each do |argv|
      assert_nil PodgenCLI::GenerateOptions.dry_parse(argv), argv.join(" ")
    end
  end

  def test_dry_parse_does_not_mutate_argv_or_print
    argv = %w[pod --help --youtube]
    out, err = capture_io { PodgenCLI::GenerateOptions.dry_parse(argv) }

    assert_equal %w[pod --help --youtube], argv
    assert_equal "", out
    assert_equal "", err
  end

  def test_dry_parse_matches_generate_command_option_values
    parsed = PodgenCLI::GenerateOptions.dry_parse(%w[pod --date 2026-01-02 --skip 1:20 --cut 30 --include A,b --from-script])

    assert_equal Date.new(2026, 1, 2), parsed[:date]
    assert_in_delta 80.0, parsed[:skip].to_f
    assert parsed[:skip].absolute
    assert_in_delta 30.0, parsed[:cut].to_f
    assert_equal Set["a", "b"], parsed[:include_words]
    assert parsed[:from_script]
    assert parsed[:force]
  end

  # --- end to end through the dispatcher ---

  def test_run_refuses_value_swallowed_terminator_and_never_builds_command
    built = false
    fake = ->(*) {
      built = true
      FakeCommand
    }

    code, out, err = PodgenCLI.stub(:const_get, fake) { run_cli("generate", "test_pod", "--title", "--", "--you") }

    assert_equal 2, code
    assert_equal "", out
    assert_equal format(REFUSAL, "generate"), err
    refute built, "refused command must never be resolved"
  end

  def test_run_refuses_global_dry_run_uploads
    code, _, err = guarded_run("--dry-run", "uploads", "x")

    assert_equal 2, code
    assert err.start_with?(format(REFUSAL, "uploads"))
  end

  def test_run_refusal_hints_when_dry_run_did_not_count
    [%w[--dry-run uploads x], %w[publish test_pod --date --dry-run], %w[generate test_pod --title --dry-run --youtube]].each do |argv|
      _, _, err = guarded_run(*argv)
      first, second = err.lines

      assert_equal format(REFUSAL, argv.find { PodgenCLI::COMMANDS.key?(it) }), first, argv.join(" ")
      assert_match(/\Anote: --dry-run was read as an option value or is not honoured by this command/, second.to_s, argv.join(" "))
    end
  end

  def test_run_refusal_without_dry_run_has_no_hint
    _, _, err = guarded_run("publish", "test_pod")

    assert_equal format(REFUSAL, "publish"), err
  end

  def test_run_global_dry_run_publish_passes_guard
    code, _, err = guarded_run("--dry-run", "publish", "test_pod")

    assert_equal 0, code
    assert_equal "", err
  end

  private

  def label(globals, cmd, argv)
    "#{globals.keys.map { "--#{it.to_s.tr("_", "-")}" }.join(" ")} #{cmd} #{argv.join(" ")}".strip
  end

  def guarded_run(*argv)
    PodgenCLI.stub(:const_get, FakeCommand) { run_cli(*argv) }
  end

  def run_cli(*args)
    old_stdout, old_stderr = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    code = PodgenCLI.run(args.flatten)
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end
end
