# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "minitest/mock"
require "cli/revocab_command"

class TestRevocabCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_revocab_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    @episodes_dir = File.join(@podcast_dir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)

    # Minimal guidelines
    File.write(File.join(@podcast_dir, "guidelines.md"), <<~MD)
      # Test Podcast

      ## Audio
      - language: sl

      ## Vocabulary
      - level: B2
    MD

    @original_env = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "test-key"
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    ENV["ANTHROPIC_API_KEY"] = @original_env
  end

  # --- resolve_transcripts ---

  def test_resolve_transcripts_finds_all
    write_transcript("testpod-2026-03-10")
    write_transcript("testpod-2026-03-11")

    cmd = build_command("testpod")
    transcripts = cmd.send(:resolve_transcripts)

    assert_equal 2, transcripts.length
  end

  def test_resolve_transcripts_finds_by_episode_id
    write_transcript("testpod-2026-03-10")
    write_transcript("testpod-2026-03-11")

    cmd = build_command("testpod", "2026-03-10")
    transcripts = cmd.send(:resolve_transcripts)

    assert_equal 1, transcripts.length
    assert_includes transcripts.first, "2026-03-10"
  end

  def test_resolve_transcripts_finds_suffixed_episode
    write_transcript("testpod-2026-03-10")
    write_transcript("testpod-2026-03-10a")

    cmd = build_command("testpod", "2026-03-10a")
    transcripts = cmd.send(:resolve_transcripts)

    assert_equal 1, transcripts.length
    assert_includes transcripts.first, "2026-03-10a"
  end

  def test_resolve_transcripts_empty_when_no_match
    write_transcript("testpod-2026-03-10")

    cmd = build_command("testpod", "2026-03-99")
    transcripts = cmd.send(:resolve_transcripts)

    assert_empty transcripts
  end

  # --- process_transcript ---

  def test_process_transcript_strips_old_vocab_and_bold
    path = write_transcript("testpod-2026-03-10", body: "He **razglasil** it.", vocab: <<~VOCAB)
      **C1**
      - **razglasiti** (v.) — to announce _Original: razglasil_
    VOCAB

    stub_annotator("marked body", "## Vocabulary\n\n**B2**\n- **new** (n.) — new word") do |cmd, annotator, logger|
      cmd.send(:process_transcript, path, annotator: annotator, language: "sl", cutoff: "B2",
                   known_lemmas: Set.new, max: nil, filters: {}, logger: logger)
    end

    content = File.read(path)
    # Old vocab stripped, new vocab present
    refute_includes content, "razglasiti"
    assert_includes content, "new word"
    # Old bold markers stripped (passed clean text to annotator)
    assert_includes content, "marked body"
  end

  def test_process_transcript_preserves_header
    path = write_transcript("testpod-2026-03-10",
      title: "My Title", description: "My description",
      body: "Some text.")

    stub_annotator("annotated text", "") do |cmd, annotator, logger|
      cmd.send(:process_transcript, path, annotator: annotator, language: "sl", cutoff: "B2",
                   known_lemmas: Set.new, max: nil, filters: {}, logger: logger)
    end

    content = File.read(path)
    assert_includes content, "# My Title"
    assert_includes content, "My description"
    assert_includes content, "## Transcript"
  end

  def test_process_transcript_handles_no_transcript_section
    path = File.join(@episodes_dir, "bad_transcript.md")
    File.write(path, "Just plain text, no sections.")

    logger = stub_logger
    stub_annotator("x", "") do |cmd, annotator, _|
      cmd.send(:process_transcript, path, annotator: annotator, language: "sl", cutoff: "B2",
                   known_lemmas: Set.new, max: nil, filters: {}, logger: logger)
    end

    # File unchanged
    assert_equal "Just plain text, no sections.", File.read(path)
  end

  # --- --date flag ---

  def test_date_flag_sets_episode_id
    cmd = PodgenCLI::RevocabCommand.new(["testpod", "--date", "2026-03-10"], {})
    assert_equal "2026-03-10", cmd.instance_variable_get(:@episode_id)
  end

  def test_date_flag_with_positional_date_is_rejected
    # Passing both is ambiguous — fail loud rather than silently dropping one.
    err = assert_raises(OptionParser::ParseError) do
      PodgenCLI::RevocabCommand.new(["testpod", "2026-01-01", "--date", "2026-03-10"], {})
    end
    assert_includes err.message, "2026-01-01"
  end

  # --- dry run ---

  def test_dry_run_does_not_modify_files
    path = write_transcript("testpod-2026-03-10", body: "Original text.")
    original = File.read(path)

    cmd = build_command("testpod", nil, dry_run: true)
    # Bypass podcast validation for test
    stub_run_setup(cmd) do
      cmd.run
    end

    assert_equal original, File.read(path)
  end

  # --- --missing-only ---

  def test_missing_only_skips_transcripts_with_vocabulary
    write_transcript("testpod-2026-03-10", body: "Has vocab.", vocab: "**B2**\n- **word** (n.) — thing")
    write_transcript("testpod-2026-03-11", body: "No vocab here.")

    cmd = build_command_verbose("testpod", nil, dry_run: true, missing_only: true)

    output = capture_io { stub_run_setup(cmd) { cmd.run } }.first
    refute_includes output, "2026-03-10"
    assert_includes output, "2026-03-11"
  end

  def test_missing_only_false_processes_all
    write_transcript("testpod-2026-03-10", body: "Has vocab.", vocab: "**B2**\n- **word** (n.) — thing")
    write_transcript("testpod-2026-03-11", body: "No vocab here.")

    cmd = build_command_verbose("testpod", nil, dry_run: true)

    output = capture_io { stub_run_setup(cmd) { cmd.run } }.first
    assert_includes output, "2026-03-10"
    assert_includes output, "2026-03-11"
  end

  # --- missing config ---

  def test_run_fails_without_vocabulary_level
    cmd = build_command("testpod")
    config = build_stub_config
    config_no_vocab = Struct.new(*config.members, keyword_init: true)
      .new(**config.to_h.merge(vocabulary_level: nil))
    cmd.instance_variable_set(:@config, config_no_vocab)

    stub_run_setup(cmd) do
      result = cmd.run
      assert_equal 2, result
    end
  end

  def test_run_fails_without_api_key
    ENV.delete("ANTHROPIC_API_KEY")

    cmd = build_command("testpod")
    stub_run_setup(cmd) do
      result = cmd.run
      assert_equal 2, result
    end
  end

  # --- --from / --to / --limit (P9-7) ---

  def test_resolve_transcripts_from_to_selects_inclusive_range
    three_months_of_fixtures

    cmd = build_command_with("--from", "2026-09-01", "--to", "2026-09-30", "testpod")
    names = cmd.send(:resolve_transcripts).map { |p| File.basename(p, "_transcript.md") }

    assert_equal %w[testpod-2026-09-01 testpod-2026-09-15 testpod-2026-09-30], names
  end

  def test_resolve_transcripts_from_only_is_open_ended
    three_months_of_fixtures

    cmd = build_command_with("--from", "2026-09-30", "testpod")
    names = cmd.send(:resolve_transcripts).map { |p| File.basename(p, "_transcript.md") }

    assert_equal %w[testpod-2026-09-30 testpod-2026-10-01 testpod-2026-10-20], names
  end

  def test_resolve_transcripts_to_only_is_open_ended
    three_months_of_fixtures

    cmd = build_command_with("--to", "2026-08-31", "testpod")
    names = cmd.send(:resolve_transcripts).map { |p| File.basename(p, "_transcript.md") }

    assert_equal %w[testpod-2026-08-10 testpod-2026-08-31], names
  end

  def test_from_rejects_malformed_date
    assert_raises(OptionParser::InvalidArgument) do
      PodgenCLI::RevocabCommand.new(["--from", "2026-09", "testpod"], {})
    end
  end

  def test_run_limit_with_from_takes_earliest_two
    three_months_of_fixtures

    cmd = build_command_with("--from", "2026-09-01", "--limit", "2", "testpod", dry_run: true)
    out = capture_io { stub_run_setup(cmd) { assert_equal 0, cmd.run } }.first

    assert_includes out, "testpod-2026-09-01"
    assert_includes out, "testpod-2026-09-15"
    refute_includes out, "testpod-2026-09-30"
    refute_includes out, "testpod-2026-08-31"
  end

  def test_run_limit_counts_after_missing_only
    write_transcript("testpod-2026-09-01", vocab: "**B2**\n- **word** (n.) — thing")
    write_transcript("testpod-2026-09-02")
    write_transcript("testpod-2026-09-03")

    cmd = build_command_with("--missing-only", "--limit", "1", "testpod", dry_run: true)
    out = capture_io { stub_run_setup(cmd) { cmd.run } }.first

    assert_includes out, "testpod-2026-09-02"
    refute_includes out, "testpod-2026-09-03"
  end

  def test_run_dry_run_lists_selection_with_count_and_writes_nothing
    three_months_of_fixtures
    before = snapshot

    cmd = build_command_with("--from", "2026-09-01", "--to", "2026-09-30", "testpod", dry_run: true)
    out = capture_io { stub_run_setup(cmd) { assert_equal 0, cmd.run } }.first

    %w[2026-09-01 2026-09-15 2026-09-30].each { |d| assert_includes out, "testpod-#{d}" }
    refute_includes out, "testpod-2026-10-01"
    assert_match(/3 transcript\(s\) selected/, out)
    assert_equal before, snapshot
  end

  def test_run_failed_file_exits_one_and_tally_names_it
    write_transcript("testpod-2026-09-01")
    write_transcript("testpod-2026-09-02")
    write_transcript("testpod-2026-09-03")

    annotator = Object.new
    annotator.define_singleton_method(:annotate) do |text, **_|
      raise "API down" if text.include?("BOOM")
      ["marked", ""]
    end
    File.write(File.join(@episodes_dir, "testpod-2026-09-02_transcript.md"),
               "# T\n\n## Transcript\n\nBOOM text")
    site = Object.new
    site.define_singleton_method(:generate) { nil }

    cmd = build_command_with("testpod")
    code = nil
    out, err = capture_io do
      stub_run_setup(cmd) do
        VocabularyAnnotator.stub(:new, annotator) do
          SiteGenerator.stub(:new, site) { code = cmd.run }
        end
      end
    end

    assert_equal 1, code
    assert_includes out, "re-annotated 2, skipped 0, failed 1 (testpod-2026-09-02)"
    assert_includes err, "testpod-2026-09-02"
  end

  def test_limit_rejects_non_positive
    [%w[--limit 0], %w[--limit -1]].each do |flag|
      assert_raises(OptionParser::InvalidArgument) do
        PodgenCLI::RevocabCommand.new(flag + ["testpod"], {})
      end
    end
  end

  def test_run_all_failed_does_not_claim_nothing_needed_annotation
    write_transcript("testpod-2026-09-01")

    annotator = Object.new
    annotator.define_singleton_method(:annotate) { |_text, **_| raise "API down" }

    cmd = build_command_with("testpod")
    code = nil
    out = capture_io do
      stub_run_setup(cmd) do
        VocabularyAnnotator.stub(:new, annotator) { code = cmd.run }
      end
    end.first

    assert_equal 1, code
    refute_includes out, "No transcripts needed annotation"
    assert_includes out, "re-annotated 0, skipped 0, failed 1 (testpod-2026-09-01)"
  end

  def test_run_all_skipped_says_nothing_needed_annotation
    write_transcript("testpod-2026-09-01", vocab: "**B2**\n- **word** (n.) — thing")

    cmd = build_command_with("--missing-only", "testpod")
    out = capture_io { stub_run_setup(cmd) { assert_equal 0, cmd.run } }.first

    assert_includes out, "No transcripts needed annotation"
  end

  def test_run_all_succeed_exits_zero_with_tally
    write_transcript("testpod-2026-09-01", vocab: "**B2**\n- **word** (n.) — thing")
    write_transcript("testpod-2026-09-02")

    annotator = Object.new
    annotator.define_singleton_method(:annotate) { |_text, **_| ["marked", ""] }
    site = Object.new
    site.define_singleton_method(:generate) { nil }

    cmd = build_command_with("--missing-only", "testpod")
    code = nil
    out = capture_io do
      stub_run_setup(cmd) do
        VocabularyAnnotator.stub(:new, annotator) do
          SiteGenerator.stub(:new, site) { code = cmd.run }
        end
      end
    end.first

    assert_equal 0, code
    assert_includes out, "re-annotated 1, skipped 1, failed 0"
  end

  # --- P9-8a: ledger per file (only earlier episodes), one shared cache ---

  def test_run_ledger_per_file_sees_only_earlier_episodes
    calls = run_capturing_annotate("testpod")
    assert_equal %w[testpod-2026-09-01 testpod-2026-09-02 testpod-2026-09-03], calls.map { |c| c[:episode] }
    assert_equal [0, 1, 2], calls.map { |c| c[:ledger].episodes }
    # "zadnji" is explained only in the last file: no ledger passed so far may see it
    assert(calls.all? { |c| c[:ledger].exposures("zadnji").zero? })
    assert_equal ["testpod-2026-09-01"], calls[2][:ledger].explained("prvi")
    caches = calls.map { |c| c[:cache] }
    assert_equal 1, caches.uniq(&:object_id).length, "one cache shared across the run"
    assert_equal File.join(@podcast_dir, "vocab_cache.yml"), caches.first.path
  end

  def test_run_no_ledger_passes_nil
    calls = run_capturing_annotate("--no-ledger", "testpod")
    assert(calls.all? { |c| c[:ledger].nil? })
    refute_nil calls.first[:cache]
  end

  def test_run_no_cache_passes_nil
    calls = run_capturing_annotate("--no-cache", "testpod")
    assert(calls.all? { |c| c[:cache].nil? })
    refute_nil calls.first[:ledger]
  end

  private

  def run_capturing_annotate(*args)
    write_transcript("testpod-2026-09-01", vocab: "- **prvi** (B2 n.) — first")
    write_transcript("testpod-2026-09-02")
    write_transcript("testpod-2026-09-03", vocab: "- **zadnji** (B2 n.) — last")
    calls = []
    annotator = Object.new
    annotator.define_singleton_method(:annotate) do |text, **kw|
      calls << kw
      # Files are rewritten in order: 09-01 keeps explaining "prvi".
      [text, kw[:episode].end_with?("09-01") ? "## Vocabulary\n\n- **prvi** (B2 n.) — first" : ""]
    end
    site = Object.new
    site.define_singleton_method(:generate) { nil }
    cmd = build_command_with(*args)
    capture_io do
      stub_run_setup(cmd) do
        VocabularyAnnotator.stub(:new, annotator) do
          SiteGenerator.stub(:new, site) { cmd.run }
        end
      end
    end
    calls
  end

  def build_command_with(*args, dry_run: false)
    cmd = PodgenCLI::RevocabCommand.new(args, { dry_run: dry_run, verbosity: :normal })
    cmd.instance_variable_set(:@config, build_stub_config)
    cmd
  end

  def three_months_of_fixtures
    %w[2026-08-10 2026-08-31 2026-09-01 2026-09-15 2026-09-30 2026-10-01 2026-10-20].each do |d|
      write_transcript("testpod-#{d}")
    end
  end

  def snapshot
    Dir[File.join(@episodes_dir, "*")].sort.to_h { |f| [f, File.read(f)] }
  end

  def write_transcript(basename, title: "Test Episode", description: "", body: "Some text.", vocab: nil)
    path = File.join(@episodes_dir, "#{basename}_transcript.md")
    content = "# #{title}\n\n"
    content += "#{description}\n\n" unless description.empty?
    content += "## Transcript\n\n#{body}"
    if vocab
      content += "\n\n## Vocabulary\n\n#{vocab}"
    end
    File.write(path, content)
    path
  end

  def build_command(podcast = "testpod", episode_id = nil, dry_run: false, missing_only: false)
    args = []
    args << "--missing-only" if missing_only
    args << podcast
    args << episode_id if episode_id
    opts = { dry_run: dry_run, verbosity: :quiet }
    cmd = PodgenCLI::RevocabCommand.new(args, opts)
    cmd.instance_variable_set(:@config, build_stub_config)
    cmd
  end

  def build_command_verbose(podcast = "testpod", episode_id = nil, dry_run: false, missing_only: false)
    args = []
    args << "--missing-only" if missing_only
    args << podcast
    args << episode_id if episode_id
    opts = { dry_run: dry_run, verbosity: :normal }
    cmd = PodgenCLI::RevocabCommand.new(args, opts)
    cmd.instance_variable_set(:@config, build_stub_config)
    cmd
  end

  def build_stub_config
    Struct.new(:podcast_dir, :episodes_dir, :transcription_language,
               :vocabulary_level, :vocabulary_max, :vocabulary_filters,
               :vocabulary_target_language, :vocabulary_target_languages,
               :history_path, :title, :description,
               :author, :languages, :base_url, :site_config, :type,
               keyword_init: true)
      .new(
        podcast_dir: @podcast_dir,
        episodes_dir: @episodes_dir,
        transcription_language: "sl",
        vocabulary_level: "B2",
        vocabulary_max: nil,
        vocabulary_filters: {},
        vocabulary_target_language: "English",
        vocabulary_target_languages: ["English"],
        history_path: File.join(@tmpdir, "history.yml"),
        title: "Test", description: nil, author: "Test",
        languages: ["sl"], base_url: nil, site_config: {},
        type: "language"
      )
  end

  def stub_logger
    logger = Object.new
    logger.define_singleton_method(:log) { |_| }
    logger.define_singleton_method(:error) { |_| }
    logger.define_singleton_method(:phase_start) { |_| }
    logger.define_singleton_method(:phase_end) { |_| }
    logger
  end

  def stub_run_setup(cmd)
    # Bypass require_podcast! and load_config! for unit tests
    cmd.define_singleton_method(:require_podcast!) { |_| nil }
    cmd.define_singleton_method(:load_config!) { @config }
    yield
  end

  def stub_annotator(marked_result, vocab_result)
    cmd = build_command("testpod")

    annotator = Object.new
    annotator.define_singleton_method(:annotate) { |text, **_| [marked_result, vocab_result] }

    logger = stub_logger
    yield cmd, annotator, logger
  end
end
