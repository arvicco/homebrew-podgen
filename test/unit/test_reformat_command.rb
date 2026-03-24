# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "cli/reformat_command"

class TestReformatCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_reformat_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    @episodes_dir = File.join(@podcast_dir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)

    File.write(File.join(@podcast_dir, "guidelines.md"), <<~MD)
      # Test Podcast

      ## Audio
      - language: sl
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

  # --- process_transcript ---

  def test_process_transcript_sends_body_to_cleanup
    path = write_transcript("testpod-2026-03-10", body: "Raw unformatted text.")

    cleanup_input = nil
    stub_reconciler(-> (text) { cleanup_input = text; "Formatted text.\n\nWith paragraphs." }) do |cmd, logger|
      cmd.send(:process_transcript, path, logger: logger)
    end

    # Body was sent to cleanup
    assert_includes cleanup_input, "Raw unformatted text."
    # Result written back
    content = File.read(path)
    assert_includes content, "Formatted text.\n\nWith paragraphs."
  end

  def test_process_transcript_preserves_header
    path = write_transcript("testpod-2026-03-10",
      title: "My Title", description: "My description", body: "Text.")

    stub_reconciler(-> (_) { "Cleaned." }) do |cmd, logger|
      cmd.send(:process_transcript, path, logger: logger)
    end

    content = File.read(path)
    assert_includes content, "# My Title"
    assert_includes content, "My description"
    assert_includes content, "## Transcript"
  end

  def test_process_transcript_preserves_vocabulary_section
    path = write_transcript("testpod-2026-03-10", body: "Text with **bold**.",
      vocab: "- **razglasiti** (C1 v.) *razglasil* — to announce")

    stub_reconciler(-> (_) { "Cleaned text." }) do |cmd, logger|
      cmd.send(:process_transcript, path, logger: logger)
    end

    content = File.read(path)
    assert_includes content, "## Vocabulary"
    assert_includes content, "razglasiti"
  end

  def test_process_transcript_reapplies_bold_markers
    path = write_transcript("testpod-2026-03-10",
      body: "He razglasil the news.",
      vocab: "- **razglasiti** (C1 v.) *razglasil* — to announce")

    stub_reconciler(-> (_) { "He razglasil the news with paragraphs." }) do |cmd, logger|
      cmd.send(:process_transcript, path, logger: logger)
    end

    content = File.read(path)
    assert_includes content, "**razglasil**"
    assert_includes content, "## Vocabulary"
  end

  def test_process_transcript_strips_bold_markers_before_cleanup
    path = write_transcript("testpod-2026-03-10", body: "He **razglasil** the news.")

    cleanup_input = nil
    stub_reconciler(-> (text) { cleanup_input = text; "Cleaned." }) do |cmd, logger|
      cmd.send(:process_transcript, path, logger: logger)
    end

    # Bold markers stripped before sending to cleanup
    refute_includes cleanup_input, "**"
    assert_includes cleanup_input, "razglasil"
  end

  def test_process_transcript_skips_no_transcript_section
    path = File.join(@episodes_dir, "bad_transcript.md")
    File.write(path, "Just plain text.")

    logger = stub_logger
    stub_reconciler(-> (_) { "x" }) do |cmd, _|
      cmd.send(:process_transcript, path, logger: logger)
    end

    assert_equal "Just plain text.", File.read(path)
  end

  # --- dry run ---

  def test_dry_run_does_not_modify_files
    path = write_transcript("testpod-2026-03-10", body: "Original text.")
    original = File.read(path)

    cmd = build_command("testpod", nil, dry_run: true)
    stub_run_setup(cmd) { cmd.run }

    assert_equal original, File.read(path)
  end

  # --- missing config ---

  def test_run_fails_without_api_key
    ENV.delete("ANTHROPIC_API_KEY")

    cmd = build_command("testpod")
    stub_run_setup(cmd) do
      _, err = capture_io { result = cmd.run; assert_equal 2, result }
      assert_includes err, "ANTHROPIC_API_KEY"
    end
  end

  private

  def write_transcript(basename, title: "Test Episode", description: "", body: "Some text.", vocab: nil)
    path = File.join(@episodes_dir, "#{basename}_transcript.md")
    content = "# #{title}\n\n"
    content += "#{description}\n\n" unless description.empty?
    content += "## Transcript\n\n#{body}"
    content += "\n\n## Vocabulary\n\n#{vocab}" if vocab
    File.write(path, content)
    path
  end

  def build_command(podcast = "testpod", episode_id = nil, dry_run: false)
    args = [podcast]
    args << episode_id if episode_id
    opts = { dry_run: dry_run, verbosity: :quiet }
    cmd = PodgenCLI::ReformatCommand.new(args, opts)
    cmd.instance_variable_set(:@config, build_stub_config)
    cmd
  end

  def build_stub_config
    Struct.new(:podcast_dir, :episodes_dir, :transcription_language,
               :history_path, :title, :description, :languages, :base_url,
               :site_config, :image, :site_css_path, :favicon_path,
               keyword_init: true)
      .new(
        podcast_dir: @podcast_dir,
        episodes_dir: @episodes_dir,
        transcription_language: "sl",
        history_path: File.join(@tmpdir, "history.yml"),
        title: "Test", description: nil,
        languages: [{ "code" => "sl" }], base_url: nil, site_config: {},
        image: nil, site_css_path: nil, favicon_path: nil
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
    cmd.define_singleton_method(:require_podcast!) { |_| nil }
    cmd.define_singleton_method(:load_config!) { @config }
    yield
  end

  def stub_reconciler(cleanup_proc)
    cmd = build_command("testpod")
    logger = stub_logger

    reconciler = Object.new
    reconciler.define_singleton_method(:cleanup) { |text, **_| cleanup_proc.call(text) }

    cmd.instance_variable_set(:@reconciler, reconciler)
    yield cmd, logger
  end
end
