# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"
require "cli"

# P3-0 H4 characterization harness: pins the CURRENT behavior of the
# dispatcher in lib/cli.rb before a refactor consolidates the help text
# (opts.separator lines) with the COMMANDS hash — today two sources of truth.
# These tests describe what the code does, not what it should do; places
# where current behavior looks wrong are marked "FLAG".
#
# No real command ever runs: every dispatch that would reach Command#run
# goes through a stubbed PodgenCLI.const_get.
class TestCharacterizationCLI < Minitest::Test
  # Full `podgen --help` output, byte for byte.
  GOLDEN_HELP = <<~HELP
    Usage: podgen [options] <command> [args]

    Fully autonomous podcast generation pipeline.

    Commands:
      generate <podcast>             Run the full pipeline (news or language)
      translate <podcast>            Translate episodes to new languages
      render <podcast> [--date|--lang] Re-render script markdown from canonical JSON
      voice <podcast> [--date|--lang|--force] Voice/re-voice from script JSON (recover from TTS failure)
      scrap <podcast> [episode|path]  Remove episode files + history entry
      move <podcast> <from> <to>     Move episode to another date (suffix '+' = whole day)
      rss <podcast>                  Generate RSS feed
      site <podcast>                 Generate static HTML website
      publish <podcast>              Publish to Cloudflare R2 (--lingq for LingQ)
      stats <podcast> | --all        Show podcast statistics
      validate <podcast> | --all     Validate config and output
      status [podcast] [--json]      OK/OLD/WARN verdict per podcast (exit 1 if any OLD/WARN)
      list                           List available podcasts
      test <name> [args]             Run a standalone test
      schedule <podcast>             Install launchd scheduler (--time, --publish, --telegram)
      uploads <pod1,pod2,...>        Per-pod regen+R2+LingQ then YT batch (--mode, --max)
      analytics <setup|deploy|tail|status>  Manage download analytics Worker
      add <podcast> <url> [--note ...]     Queue a priority link for next episode
      links <podcast> [--remove|--clear]   List or manage queued priority links
      vocab <add|remove|list> <podcast>    Manage known vocabulary words
      revocab <podcast> [episode] [--missing-only]  Re-annotate vocabulary
      reformat <podcast> [episode]         Reformat transcripts (paragraph breaks, cleanup)
      exclude <podcast> <url> [url...]     Exclude URLs from future episodes
      cover <podcast> <title|episode-id>   Generate episode cover image
      regen <podcast> [date] [--video|--subtitles|--reconcile|--all]  Regenerate post-pipeline artifacts
      init <name> | <source> <name>      Initialize a new podcast (skeleton or from existing)
      fork <old> <new>                   Fork podcast with all content into a new namespace
      unpublish <podcast>                Remove podcast from Cloudflare R2
      tweet <podcast> <episode-id>       Tweet about an episode (--force, --dry-run)

    Pipelines (configured via ## Type in guidelines.md):
      news      Research topics, write script, TTS, assemble MP3 (default)
      language  Download from RSS, --file, or --url (YouTube), transcribe, assemble MP3

    Transcription engines (## Transcription Engine in guidelines.md):
      open      OpenAI Whisper / gpt-4o-transcribe (default)
      elab      ElevenLabs Scribe v2
      groq      Groq hosted Whisper
      List multiple engines for side-by-side comparison mode.

    Tests:
      research, rss, hn, claude_web, bluesky, x, script, tts,
      assembly, translation, transcription, sources
      Example: podgen test transcription lahko_noc elab
               podgen test transcription audio.mp3 all

    Options:
        -v, --verbose                    Verbose output
        -q, --quiet                      Suppress terminal output (errors still shown)
            --dry-run                    Validate config, skip API calls and file output
            --lingq                      Enable LingQ upload (generate) or publish to LingQ (publish)
        -V, --version                    Print version and exit
        -h, --help                       Show this help
  HELP

  # COMMANDS entries whose description appears verbatim on their help line.
  HELP_DESCRIPTION_VERBATIM = %w[
    translate site stats list schedule analytics links vocab exclude cover
    init unpublish tweet
  ].freeze

  # FLAG (two sources of truth): COMMANDS description vs the help line's
  # description text, for every command where they have drifted apart.
  HELP_DESCRIPTION_DRIFT = {
    "generate" => ["Run the full podcast pipeline", "Run the full pipeline (news or language)"],
    "render" => ["Re-render script markdown from JSON", "Re-render script markdown from canonical JSON"],
    "voice" => ["Voice or re-voice an episode from JSON", "Voice/re-voice from script JSON (recover from TTS failure)"],
    "scrap" => ["Remove episode and history entry", "Remove episode files + history entry"],
    "move" => ["Move an episode (or whole day) to a different date", "Move episode to another date (suffix '+' = whole day)"],
    "rss" => ["Generate RSS feed for a podcast", "Generate RSS feed"],
    "publish" => ["Publish to Cloudflare R2 or LingQ", "Publish to Cloudflare R2 (--lingq for LingQ)"],
    "validate" => ["Validate podcast config and output", "Validate config and output"],
    "status" => ["One-line OK/OLD/WARN verdict per podcast", "OK/OLD/WARN verdict per podcast (exit 1 if any OLD/WARN)"],
    "test" => ["Run a standalone test script", "Run a standalone test"],
    "add" => ["Add a priority link for next episode", "Queue a priority link for next episode"],
    "revocab" => ["Re-annotate vocabulary on transcripts", "Re-annotate vocabulary"],
    "reformat" => ["Reformat transcripts with paragraph breaks", "Reformat transcripts (paragraph breaks, cleanup)"],
    "regen" => ["Regenerate video / subtitles / reconciliation for an existing episode", "Regenerate post-pipeline artifacts"],
    "fork" => ["Fork podcast into a new namespace", "Fork podcast with all content into a new namespace"],
    "uploads" => ["Per-pod regen+R2+LingQ then YT batch across pods", "Per-pod regen+R2+LingQ then YT batch (--mode, --max)"]
  }.freeze

  REFUSAL = "podgen: '%s' is an owner action; refusing inside a Claude Code session (PODGEN_OWNER=1 overrides)\n"

  def setup
    @tmpdir = Dir.mktmpdir("podgen_char_cli")
    FileUtils.mkdir_p(File.join(@tmpdir, "podcasts", "test_pod"))
    File.write(File.join(@tmpdir, "podcasts", "test_pod", "guidelines.md"), "## Podcast\n- name: Test Pod\n")
    ENV["PODGEN_ROOT"] = @tmpdir
    ENV.delete("CLAUDECODE")
    ENV.delete("PODGEN_OWNER")
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    ENV.delete("CLAUDECODE")
    ENV.delete("PODGEN_OWNER")
    FileUtils.rm_rf(@tmpdir)
  end

  # Never executes a real command: const_get returns a fake whose #run is a no-op.
  class FakeCommand
    def initialize(*) = nil
    def run = 0
  end

  # Builds the REAL command (so constructor-level parse errors surface through
  # the dispatcher) but returns a FakeCommand, so #run never executes.
  class ConstructOnly
    def initialize(real) = @real = real

    def new(argv, options)
      @real.new(argv, options)
      FakeCommand.new
    end
  end

  # --- help text (golden) ---

  def test_run_help_flag_prints_golden_help_and_returns_zero
    code, out, err = run_cli("--help")

    assert_equal 0, code
    assert_equal GOLDEN_HELP, out
    assert_equal "", err
  end

  def test_run_short_help_flag_prints_same_golden_help
    code, out, = run_cli("-h")

    assert_equal 0, code
    assert_equal GOLDEN_HELP, out
  end

  def test_run_no_command_prints_golden_help_to_stdout_and_returns_two
    code, out, err = run_cli

    assert_equal 2, code
    assert_equal GOLDEN_HELP, out
    assert_equal "", err
  end

  def test_run_version_flag_prints_version_and_returns_zero
    code, out, = run_cli("--version")

    assert_equal 0, code
    assert_equal "podgen #{PodgenCLI::VERSION}\n", out
  end

  # --- COMMANDS vs help (two sources of truth) ---

  def test_commands_hash_lists_29_commands_in_pinned_order
    expected = %w[
      generate translate render voice scrap move rss site publish stats
      validate status list test schedule analytics add links vocab revocab
      reformat exclude cover regen init fork unpublish tweet uploads
    ]

    assert_equal expected, PodgenCLI::COMMANDS.keys
  end

  def test_help_every_command_name_has_exactly_one_help_line
    help_lines = GOLDEN_HELP.lines.grep(/\A  \S/)

    PodgenCLI::COMMANDS.each_key do |name|
      matching = help_lines.select { |l| l.start_with?("  #{name} ") || l.rstrip == "  #{name}" }
      assert_equal 1, matching.size, "#{name} must appear on exactly one help line"
    end
  end

  def test_help_command_order_differs_from_commands_hash_order
    # FLAG: help lists `uploads` right after `schedule`; COMMANDS has it last.
    command_lines = GOLDEN_HELP.lines.drop_while { |l| l != "Commands:\n" }.drop(1).take_while { |l| l != "\n" }
    help_order = command_lines.map { |l| l.split.first }

    assert_equal PodgenCLI::COMMANDS.keys.sort, help_order.sort
    refute_equal PodgenCLI::COMMANDS.keys, help_order
    assert_equal "uploads", help_order[help_order.index("schedule") + 1]
  end

  def test_help_description_verbatim_for_pinned_commands
    HELP_DESCRIPTION_VERBATIM.each do |name|
      desc = PodgenCLI::COMMANDS.fetch(name).first
      line = help_line_for(name)
      assert_includes line, desc, "#{name}: COMMANDS description should appear verbatim in help"
    end
  end

  def test_help_description_drifted_from_commands_hash_for_pinned_commands
    HELP_DESCRIPTION_DRIFT.each do |name, (commands_desc, help_desc)|
      line = help_line_for(name)
      assert_equal commands_desc, PodgenCLI::COMMANDS.fetch(name).first, name
      refute_includes line, commands_desc, "#{name}: drift no longer present — update the pin"
      assert line.end_with?(help_desc), "#{name}: help line was #{line.inspect}"
    end
  end

  def test_help_verbatim_and_drift_partition_all_commands
    assert_equal PodgenCLI::COMMANDS.keys.sort, (HELP_DESCRIPTION_VERBATIM + HELP_DESCRIPTION_DRIFT.keys).sort
    assert_empty HELP_DESCRIPTION_VERBATIM & HELP_DESCRIPTION_DRIFT.keys
  end

  def test_commands_entries_require_paths_and_class_names_follow_convention
    PodgenCLI::COMMANDS.each do |name, (_desc, path, klass)|
      assert_equal "cli/#{name}_command", path
      assert_equal "#{name.capitalize}Command", klass
    end
  end

  # --- owner actions ---

  def test_owner_actions_constant_pinned
    assert_equal %w[publish unpublish uploads tweet schedule analytics], PodgenCLI::OWNER_ACTIONS
    assert_equal %w[--youtube --lingq], PodgenCLI::OWNER_FLAGS
    assert PodgenCLI::OWNER_ACTIONS.frozen?
  end

  def test_owner_actions_are_all_dispatchable_commands
    assert_empty PodgenCLI::OWNER_ACTIONS - PodgenCLI::COMMANDS.keys
  end

  def test_owner_action_predicate_classifies_every_command_without_flags
    PodgenCLI::COMMANDS.each_key do |name|
      expected = PodgenCLI::OWNER_ACTIONS.include?(name)
      assert_equal expected, PodgenCLI.owner_action?(name, ["test_pod"], {}), name
    end
  end

  def test_owner_action_predicate_generate_flags_and_global_lingq_count
    assert PodgenCLI.owner_action?("generate", ["p", "--youtube"], {})
    assert PodgenCLI.owner_action?("generate", ["p", "--lingq"], {})
    assert PodgenCLI.owner_action?("generate", ["p"], {lingq: true})
    refute PodgenCLI.owner_action?("generate", ["p"], {})
  end

  def test_owner_action_predicate_upload_flags_on_other_commands_ignored
    refute PodgenCLI.owner_action?("rss", ["p", "--youtube"], {})
    refute PodgenCLI.owner_action?("regen", ["p", "--lingq"], {lingq: true})
  end

  def test_owner_action_predicate_abbreviated_generate_upload_flags_detected
    # P3-7: GenerateCommand's OptionParser expands unique (case-insensitive)
    # prefixes, so `generate p --you` sets youtube and `--lin` sets lingq. The
    # guard treats any prefix of an owner flag as that flag.
    [
      ["p", "--you"], ["p", "--y"], ["p", "--yout"], ["p", "--lin"], ["p", "--ling"],
      ["p", "--l"], ["p", "--YOU"], ["p", "--you=1"], ["p", "--youtube=1"],
      ["--you", "p"], ["p", "--force", "--lin", "--dry"]
    ].each do |argv|
      assert PodgenCLI.owner_action?("generate", argv, {}), argv.join(" ")
    end
  end

  def test_owner_action_predicate_non_prefix_flags_not_detected
    [
      ["p", "--yes"], ["p", "--youtuber"], ["p", "--lingqs"], ["p", "--no-youtube"],
      ["p", "--"], ["p", "--force"], ["p", "--lang", "you"], ["p", "-f"], ["p", "-x"]
    ].each do |argv|
      refute PodgenCLI.owner_action?("generate", argv, {}), argv.join(" ")
    end
  end

  def test_owner_action_predicate_single_dash_completions_detected
    # GenerateCommand defines no short options, so OptionParser completes a
    # single-dash letter against the long options: `-y` sets youtube, `-l`
    # sets lingq. Any `-y…` / `-l…` token counts as an owner flag.
    [
      ["p", "-y"], ["p", "-Y"], ["p", "-l"], ["p", "-L"], ["p", "-yfoo"], ["p", "-y=1"],
      ["-y", "p"]
    ].each do |argv|
      assert PodgenCLI.owner_action?("generate", argv, {}), argv.join(" ")
    end
    refute PodgenCLI.owner_action?("generate", ["p", "--", "-y"], {})
  end

  def test_owner_action_predicate_tokens_after_terminator_not_detected
    # Everything after a lone `--` is positional to OptionParser, never a flag.
    refute PodgenCLI.owner_action?("generate", ["p", "--", "--you"], {})
    refute PodgenCLI.owner_action?("generate", ["p", "--", "--youtube"], {})
    assert PodgenCLI.owner_action?("generate", ["p", "--lin", "--", "x"], {})
  end

  def test_owner_action_predicate_abbreviations_on_other_commands_ignored
    refute PodgenCLI.owner_action?("rss", ["p", "--you"], {})
    refute PodgenCLI.owner_action?("regen", ["p", "--lin"], {})
  end

  def test_run_refusal_for_abbreviated_generate_upload_flag_command_never_built
    ENV["CLAUDECODE"] = "1"
    [%w[generate test_pod --you], %w[generate --lin test_pod]].each do |argv|
      built = false
      fake = ->(*) {
        built = true
        FakeCommand
      }

      code, out, err = PodgenCLI.stub(:const_get, fake) { run_cli(*argv) }

      assert_equal 2, code, argv.join(" ")
      assert_equal "", out, argv.join(" ")
      assert_equal format(REFUSAL, "generate"), err, argv.join(" ")
      refute built, "#{argv.join(" ")}: refused command must never be resolved"
    end
  end

  def test_run_refusal_message_exact_and_command_never_built
    ENV["CLAUDECODE"] = "1"
    PodgenCLI::OWNER_ACTIONS.each do |cmd|
      built = false
      fake = ->(*) {
        built = true
        FakeCommand
      }

      code, out, err = PodgenCLI.stub(:const_get, fake) { run_cli(cmd, "test_pod") }

      assert_equal 2, code, cmd
      assert_equal "", out, cmd
      assert_equal format(REFUSAL, cmd), err, cmd
      refute built, "#{cmd}: refused command must never be resolved"
    end
  end

  def test_run_refusal_only_for_exact_claudecode_one
    %w[0 true yes].each do |value|
      ENV["CLAUDECODE"] = value
      code, _, err = guarded_run("publish", "test_pod")
      assert_equal 0, code, "CLAUDECODE=#{value} leaves the guard inert"
      refute_includes err, "owner action"
    end
  end

  def test_run_owner_override_only_for_exact_podgen_owner_one
    ENV["CLAUDECODE"] = "1"
    %w[0 true yes].each do |value|
      ENV["PODGEN_OWNER"] = value
      code, _, err = guarded_run("publish", "test_pod")
      assert_equal 2, code, "PODGEN_OWNER=#{value} does not override"
      assert_equal format(REFUSAL, "publish"), err
    end
    ENV["PODGEN_OWNER"] = "1"
    code, _, err = guarded_run("publish", "test_pod")
    assert_equal 0, code
    assert_equal "", err
  end

  def test_run_global_dry_run_before_command_passes_guard
    ENV["CLAUDECODE"] = "1"
    code, _, err = guarded_run("--dry-run", "uploads", "a,b")

    assert_equal 0, code
    assert_equal "", err
  end

  def test_run_generate_upload_flag_with_dry_run_passes_guard
    ENV["CLAUDECODE"] = "1"
    code, _, err = guarded_run("generate", "test_pod", "--dry-run", "--youtube")

    assert_equal 0, code
    assert_equal "", err
  end

  def test_refuse_owner_action_dry_run_exempt_only_when_not_a_value
    ENV["CLAUDECODE"] = "1"
    # An option taking a value swallows the next token, so `--dry-run` right
    # after a bare option may be that option's value: no exemption then.
    {
      ["publish", ["pod", "--dry-run"]] => false,
      ["publish", ["pod", "--date=2026-01-01", "--dry-run"]] => false,
      ["publish", ["--dry-run", "pod"]] => false,
      ["publish", ["pod", "--date", "--dry-run"]] => true,
      ["tweet", ["pod", "ep", "--template", "--dry-run"]] => true,
      ["generate", ["pod", "--youtube", "--include", "--dry-run"]] => true,
      ["generate", ["pod", "--youtube", "--dry-run"]] => true,
      ["publish", ["pod", "--dry"]] => true,
      ["publish", ["pod", "--DRY-RUN"]] => true,
      ["publish", ["pod", "--", "--dry-run"]] => true
    }.each do |(cmd, argv), refused|
      assert_equal refused, PodgenCLI.refuse_owner_action?(cmd, argv, {}), "#{cmd} #{argv.join(" ")}"
    end
  end

  def test_run_refusal_for_single_dash_youtube_command_never_built
    ENV["CLAUDECODE"] = "1"
    built = false
    fake = ->(*) {
      built = true
      FakeCommand
    }

    code, out, err = PodgenCLI.stub(:const_get, fake) { run_cli("generate", "test_pod", "-y") }

    assert_equal 2, code
    assert_equal "", out
    assert_equal format(REFUSAL, "generate"), err
    refute built, "refused command must never be resolved"
  end

  def test_run_refusal_for_publish_with_value_swallowed_dry_run
    ENV["CLAUDECODE"] = "1"
    code, _, err = guarded_run("publish", "test_pod", "--date", "--dry-run")

    assert_equal 2, code
    assert_equal format(REFUSAL, "publish"), err
  end

  def test_run_generate_without_upload_flags_not_refused
    ENV["CLAUDECODE"] = "1"
    code, _, err = guarded_run("generate", "test_pod")

    assert_equal 0, code
    assert_equal "", err
  end

  def test_run_refusal_for_global_lingq_before_generate
    ENV["CLAUDECODE"] = "1"
    code, _, err = guarded_run("--lingq", "generate", "test_pod")

    assert_equal 2, code
    assert_equal format(REFUSAL, "generate"), err
  end

  def test_run_refusal_precedes_unknown_option_parsing
    # The guard runs before the command parses its own options, so an owner
    # command with a bad option is refused (not reported as invalid option).
    ENV["CLAUDECODE"] = "1"
    code, _, err = guarded_run("tweet", "test_pod", "--bogus")

    assert_equal 2, code
    assert_equal format(REFUSAL, "tweet"), err
  end

  # --- unknown command / global options ---

  def test_run_unknown_command_prints_message_and_golden_help_to_stderr
    code, out, err = run_cli("frobnicate", "x")

    assert_equal 2, code
    assert_equal "", out
    assert_equal "Unknown command: frobnicate\n\n#{GOLDEN_HELP}", err
  end

  def test_run_unknown_command_checked_before_owner_guard
    ENV["CLAUDECODE"] = "1"
    code, _, err = run_cli("publsh", "x")

    assert_equal 2, code
    assert err.start_with?("Unknown command: publsh\n")
  end

  def test_run_command_names_are_case_sensitive
    code, _, err = run_cli("Generate", "test_pod")

    assert_equal 2, code
    assert err.start_with?("Unknown command: Generate\n")
  end

  def test_run_invalid_global_option_prints_message_and_golden_help_to_stderr
    code, out, err = run_cli("--bogus", "list")

    assert_equal 2, code
    assert_equal "", out
    assert_equal "invalid option: --bogus\n\n#{GOLDEN_HELP}", err
  end

  def test_run_global_options_stop_at_command_name
    # `order!` stops at the first non-option, so `-v` after the command is
    # left for the command's own parser (list ignores it).
    seen = nil
    capture = ->(*) {
      Class.new {
        define_method(:initialize) { |argv, opts| seen = [argv.dup, opts.dup] }
        define_method(:run) { 0 }
      }
    }

    code, = PodgenCLI.stub(:const_get, capture) { run_cli("-q", "list", "-v") }

    assert_equal 0, code
    assert_equal [["-v"], {verbosity: :quiet}], seen
  end

  # --- leftover positional args ---

  # Exact stderr for `podgen <cmd> test_pod a1 a2 a3 a4 zz_leftover`, built for
  # real and dispatched with #run stubbed. nil = accepted (exit 0).
  LEFTOVER_EXPECTATIONS = {
    "generate" => "a1 a2 a3 a4 zz_leftover",
    "translate" => "a1 a2 a3 a4 zz_leftover",
    "render" => "a1 a2 a3 a4 zz_leftover",
    "voice" => "a1 a2 a3 a4 zz_leftover",
    "scrap" => "a1 a2 a3 a4 zz_leftover",
    "move" => "a3 a4 zz_leftover",
    "rss" => "a1 a2 a3 a4 zz_leftover",
    "site" => "a1 a2 a3 a4 zz_leftover",
    "publish" => "a2 a3 a4 zz_leftover",
    "stats" => "a1 a2 a3 a4 zz_leftover",
    "validate" => "a1 a2 a3 a4 zz_leftover",
    "status" => "a1 a2 a3 a4 zz_leftover",
    "list" => nil, # FLAG: list silently ignores every positional argument
    "test" => nil, # varargs by design (test args)
    "schedule" => "a1 a2 a3 a4 zz_leftover",
    "analytics" => "a1 a2 a3 a4 zz_leftover",
    "add" => "a2 a3 a4 zz_leftover",
    "links" => "a1 a2 a3 a4 zz_leftover",
    "vocab" => "a3 a4 zz_leftover",
    "revocab" => "a2 a3 a4 zz_leftover",
    "reformat" => "a2 a3 a4 zz_leftover",
    "exclude" => nil, # varargs by design (URLs)
    "cover" => "a1 a2 a3 a4 zz_leftover",
    "regen" => "a1 a2 a3 a4 zz_leftover",
    "init" => "a2 a3 a4 zz_leftover",
    "fork" => "a2 a3 a4 zz_leftover",
    "unpublish" => "a1 a2 a3 a4 zz_leftover",
    "tweet" => "a2 a3 a4 zz_leftover",
    "uploads" => "a1 a2 a3 a4 zz_leftover"
  }.freeze

  def test_run_leftover_positional_args_rejected_per_command
    assert_equal PodgenCLI::COMMANDS.keys.sort, LEFTOVER_EXPECTATIONS.keys.sort

    LEFTOVER_EXPECTATIONS.each do |name, leftover|
      code, out, err = construct_only_run(name, "test_pod", "a1", "a2", "a3", "a4", "zz_leftover")

      assert_equal "", out, name
      if leftover
        assert_equal 2, code, name
        assert_equal "#{name}: parse error: unexpected argument(s): #{leftover}\n", err, name
      else
        assert_equal 0, code, name
        assert_equal "", err, name
      end
    end
  end

  private

  def help_line_for(name)
    GOLDEN_HELP.lines.find { |l| l.start_with?("  #{name} ") || l.rstrip == "  #{name}" }.rstrip
  end

  def guarded_run(*argv)
    PodgenCLI.stub(:const_get, FakeCommand) { run_cli(*argv) }
  end

  def construct_only_run(*argv)
    real_const_get = PodgenCLI.method(:const_get)
    _, path, = PodgenCLI::COMMANDS.fetch(argv.first)
    require path
    proxy = ->(name) { ConstructOnly.new(real_const_get.call(name)) }
    PodgenCLI.stub(:const_get, proxy) { run_cli(*argv) }
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
