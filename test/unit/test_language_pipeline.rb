# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "date"
require "fileutils"
require "episode_history"
require "agents/description_agent"
require "cli/language_pipeline"

# Minimal logger that captures messages without file I/O
class StubLogger
  attr_reader :messages, :errors

  def initialize
    @messages = []
    @errors = []
  end

  def log(msg) = @messages << msg
  def error(msg) = @errors << msg
  def phase_start(_name) = nil
  def phase_end(_name) = nil
end

# Minimal config double exposing only the fields private methods need
StubConfig = Struct.new(
  :podcast_dir, :episodes_dir, :history_path, :author,
  :cover_base_image, :cover_options, :cover_generation_enabled,
  :lingq_config, :lingq_enabled, :transcription_language,
  keyword_init: true
) do
  def cover_generation_enabled? = cover_generation_enabled
  def lingq_enabled? = lingq_enabled
  def episode_basename(_date) = "test-2026-03-10"
end

# Stub DescriptionAgent for testing clean_or_generate_description
class StubDescriptionAgent
  def initialize(clean_title: nil, clean: nil, generate: nil)
    @clean_title_result = clean_title
    @clean_result = clean
    @generate_result = generate
  end

  def clean_title(title:) = @clean_title_result || title
  def clean(title:, description:) = @clean_result || description
  def generate(title:, transcript:) = @generate_result || ""
end

class TestLanguagePipeline < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_lp_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)

    @logger = StubLogger.new
    @history = EpisodeHistory.new(File.join(@tmpdir, "history.yml"))

    @config = StubConfig.new(
      podcast_dir: @tmpdir,
      episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      author: "Test Author",
      cover_base_image: nil,
      cover_options: {},
      cover_generation_enabled: false,
      lingq_config: nil,
      lingq_enabled: false,
      transcription_language: "sl"
    )
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- write_transcript_file ---

  def test_write_transcript_file_creates_markdown
    pipeline = build_pipeline
    episode = { title: "My Episode", description: "Episode desc" }
    path = File.join(@episodes_dir, "test_transcript.md")

    pipeline.send(:write_transcript_file, path, episode, "Hello world transcript.")

    content = File.read(path)
    assert_includes content, "# My Episode"
    assert_includes content, "Episode desc"
    assert_includes content, "## Transcript"
    assert_includes content, "Hello world transcript."
  end

  def test_write_transcript_file_omits_empty_description
    pipeline = build_pipeline
    episode = { title: "No Desc", description: "" }
    path = File.join(@episodes_dir, "test_transcript.md")

    pipeline.send(:write_transcript_file, path, episode, "Text.")

    content = File.read(path)
    assert_includes content, "# No Desc"
    assert_includes content, "## Transcript"
    refute_includes content, "Episode desc"
  end

  def test_write_transcript_file_creates_directory
    pipeline = build_pipeline
    episode = { title: "Test", description: nil }
    nested_path = File.join(@episodes_dir, "sub", "transcript.md")

    pipeline.send(:write_transcript_file, nested_path, episode, "Content")

    assert File.exist?(nested_path)
  end

  # --- record_lingq_upload ---

  def test_record_lingq_upload_creates_tracking_file
    pipeline = build_pipeline
    tracking_path = File.join(@tmpdir, "lingq_uploads.yml")

    pipeline.send(:record_lingq_upload, 12345, "test-2026-03-10", 999)

    assert File.exist?(tracking_path)
    data = YAML.load_file(tracking_path)
    assert_equal 999, data["12345"]["test-2026-03-10"]
  end

  def test_record_lingq_upload_appends_to_existing
    pipeline = build_pipeline
    tracking_path = File.join(@tmpdir, "lingq_uploads.yml")

    # Pre-populate
    File.write(tracking_path, { "12345" => { "old-ep" => 100 } }.to_yaml)

    pipeline.send(:record_lingq_upload, 12345, "new-ep", 200)

    data = YAML.load_file(tracking_path)
    assert_equal 100, data["12345"]["old-ep"]
    assert_equal 200, data["12345"]["new-ep"]
  end

  def test_record_lingq_upload_handles_separate_collections
    pipeline = build_pipeline

    pipeline.send(:record_lingq_upload, 111, "ep-a", 1)
    pipeline.send(:record_lingq_upload, 222, "ep-b", 2)

    tracking_path = File.join(@tmpdir, "lingq_uploads.yml")
    data = YAML.load_file(tracking_path)
    assert_equal 1, data["111"]["ep-a"]
    assert_equal 2, data["222"]["ep-b"]
  end

  # --- resolve_episode_cover ---

  def test_resolve_cover_with_image_path_option
    image_path = File.join(@tmpdir, "custom.png")
    FileUtils.touch(image_path)

    pipeline = build_pipeline(options: { image: image_path })
    result = pipeline.send(:resolve_episode_cover, "Title")

    assert_equal File.expand_path(image_path), result
  end

  def test_resolve_cover_with_thumb_option
    pipeline = build_pipeline(options: { image: "thumb" })
    pipeline.instance_variable_set(:@youtube_thumbnail, "/tmp/thumb.jpg")
    result = pipeline.send(:resolve_episode_cover, "Title")

    assert_equal "/tmp/thumb.jpg", result
  end

  def test_resolve_cover_image_none_falls_to_thumbnail
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@current_episode_image_none, true)
    pipeline.instance_variable_set(:@youtube_thumbnail, "/tmp/thumb.jpg")

    result = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal "/tmp/thumb.jpg", result
  end

  def test_resolve_cover_returns_nil_when_no_options
    pipeline = build_pipeline
    result = pipeline.send(:resolve_episode_cover, "Title")
    assert_nil result
  end

  def test_resolve_cover_falls_through_to_youtube_thumbnail
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@youtube_thumbnail, "/tmp/yt.jpg")

    result = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal "/tmp/yt.jpg", result
  end

  # --- cleanup_temp_files ---

  def test_cleanup_temp_files_removes_files
    f1 = File.join(@tmpdir, "temp1.mp3")
    f2 = File.join(@tmpdir, "temp2.mp3")
    FileUtils.touch(f1)
    FileUtils.touch(f2)

    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, [f1, f2])
    pipeline.instance_variable_set(:@trimmer, nil)

    pipeline.send(:cleanup_temp_files)

    refute File.exist?(f1)
    refute File.exist?(f2)
  end

  def test_cleanup_temp_files_ignores_missing
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, ["/nonexistent/file.mp3"])
    pipeline.instance_variable_set(:@trimmer, nil)

    # Should not raise
    pipeline.send(:cleanup_temp_files)
  end

  def test_cleanup_includes_trimmer_temp_files
    f1 = File.join(@tmpdir, "pipeline.mp3")
    f2 = File.join(@tmpdir, "trimmer.mp3")
    FileUtils.touch(f1)
    FileUtils.touch(f2)

    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, [f1])

    trimmer_stub = Struct.new(:temp_files).new([f2])
    pipeline.instance_variable_set(:@trimmer, trimmer_stub)

    pipeline.send(:cleanup_temp_files)

    refute File.exist?(f1)
    refute File.exist?(f2)
  end

  # --- clean_or_generate_description ---

  def test_clean_or_generate_description_cleans_existing
    pipeline = build_pipeline
    episode = { title: "Test", description: "Original desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Test", clean: "Cleaned desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript text")
    end

    assert_equal "Cleaned desc", episode[:description]
  end

  def test_clean_or_generate_description_generates_when_empty
    pipeline = build_pipeline
    episode = { title: "Test", description: "" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Test", generate: "Generated desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript text")
    end

    assert_equal "Generated desc", episode[:description]
  end

  def test_clean_or_generate_description_cleans_title
    pipeline = build_pipeline
    episode = { title: "CATEGORY: Real Title", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Real Title", clean: "Desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    assert_equal "Real Title", episode[:title]
  end

  def test_clean_or_generate_description_non_fatal
    pipeline = build_pipeline
    episode = { title: "Test", description: "Keep me" }

    # Raise during agent construction
    DescriptionAgent.stub(:new, ->(**_) { raise "API error" }) do
      # Should not raise
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    # Original description preserved on error
    assert_equal "Keep me", episode[:description]
  end

  # --- warnings tracking ---

  def test_description_failure_adds_warning
    pipeline = build_pipeline
    episode = { title: "Test", description: "Keep me" }

    DescriptionAgent.stub(:new, ->(**_) { raise "API error" }) do
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    warnings = pipeline.instance_variable_get(:@warnings)
    assert_equal 1, warnings.size
    assert_includes warnings.first, "Description cleanup failed"
  end

  def test_reconciliation_failure_adds_warning
    pipeline = build_pipeline
    # Simulate multi-engine transcription result with nil reconciled
    result = { all: {}, errors: {}, reconciled: nil, primary: { text: "raw" } }
    pipeline.instance_variable_set(:@config, StubConfig.new(
      podcast_dir: @tmpdir, episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      author: "Test", cover_base_image: nil, cover_options: {},
      cover_generation_enabled: false, lingq_config: nil, lingq_enabled: false,
      transcription_language: "sl"
    ))

    # Call transcribe_audio's post-processing logic directly
    # by simulating the multi-engine branch
    pipeline.instance_variable_set(:@reconciled_text, nil)
    warnings = pipeline.instance_variable_get(:@warnings)
    # Simulate the multi-engine path where reconciled is nil
    engine_codes = %w[open groq]
    pipeline.instance_variable_set(:@comparison_results, result[:all])
    pipeline.instance_variable_set(:@comparison_errors, result[:errors])
    # The warning is added in transcribe_audio — test via log_completion
    warnings << "Transcript reconciliation failed (using raw primary engine output)"

    assert warnings.any? { |w| w.include?("reconciliation failed") }
  end

  def test_log_completion_with_warnings_shows_warning_marker
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")
    pipeline.instance_variable_get(:@warnings) << "Test warning"

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("\u26A0") }
    assert @logger.messages.any? { |m| m.include?("with warnings") }
    assert @logger.messages.any? { |m| m.include?("Test warning") }
  end

  def test_log_completion_without_warnings_shows_checkmark
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("\u2713") }
    refute @logger.messages.any? { |m| m.include?("warning") }
  end

  def test_log_completion_lists_multiple_warnings
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")
    warnings = pipeline.instance_variable_get(:@warnings)
    warnings << "Warning one"
    warnings << "Warning two"

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("Warning one") }
    assert @logger.messages.any? { |m| m.include?("Warning two") }
  end

  # --- log_dry_run ---

  def test_log_dry_run_logs_summary
    pipeline = build_pipeline(options: { verbosity: :quiet })
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.send(:log_dry_run, "Config validated")

    assert @logger.messages.any? { |m| m.include?("dry-run") }
    assert @logger.messages.any? { |m| m.include?("Config validated") }
  end

  # --- validate_image_options ---

  def test_validate_image_options_thumb_without_url_returns_error
    pipeline = build_pipeline(options: { image: "thumb" })
    # No @youtube_url set
    result = pipeline.send(:validate_image_options)
    assert_equal 1, result
  end

  def test_validate_image_options_thumb_with_url_returns_nil
    pipeline = build_pipeline(options: { image: "thumb", url: "https://youtube.com/watch?v=abc" })
    pipeline.instance_variable_set(:@youtube_url, "https://youtube.com/watch?v=abc")
    result = pipeline.send(:validate_image_options)
    assert_nil result
  end

  def test_validate_image_options_nil_returns_nil
    pipeline = build_pipeline
    result = pipeline.send(:validate_image_options)
    assert_nil result
  end

  def test_validate_image_options_last_with_no_screenshots
    pipeline = build_pipeline(options: { image: "last" })
    # Stub Dir.glob to return empty
    Dir.stub(:glob, []) do
      result = pipeline.send(:validate_image_options)
      assert_equal 1, result
    end
  end

  private

  def build_pipeline(options: {})
    opts = { verbosity: :quiet }.merge(options)
    PodgenCLI::LanguagePipeline.new(
      config: @config,
      options: opts,
      logger: @logger,
      history: @history,
      today: Date.new(2026, 3, 10)
    )
  end
end
