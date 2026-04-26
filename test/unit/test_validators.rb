# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "podcast_validator"

# Direct unit tests for each Validators:: class and PodcastValidator orchestrator.
# Covers edge cases not exercised by test_validate_command.rb (which tests through
# PodcastValidator delegation methods).
class TestValidators < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_validators_test")
    @podcast_dir = File.join(@tmpdir, "mypod")
    @episodes_dir = File.join(@podcast_dir, "episodes")
    @guidelines_path = File.join(@podcast_dir, "guidelines.md")
    @history_path = File.join(@podcast_dir, "history.yml")
    @feed_path = File.join(@podcast_dir, "feed.xml")
    @queue_path = File.join(@podcast_dir, "queue.yml")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- BaseValidator ---

  def test_base_validator_check_raises_not_implemented
    v = Validators::BaseValidator.new(stub_config)
    assert_raises(NotImplementedError) { v.validate }
  end

  def test_base_validator_format_size_class_method
    assert_equal "500 B", Validators::BaseValidator.format_size(500)
    assert_equal "10 KB", Validators::BaseValidator.format_size(10_000)
    assert_equal "1.5 MB", Validators::BaseValidator.format_size(1_500_000)
    assert_equal "2.3 GB", Validators::BaseValidator.format_size(2_300_000_000)
  end

  # --- CoverValidator ---

  def test_cover_too_large
    File.write(File.join(@podcast_dir, "cover.jpg"), "x" * 6_000_000)
    result = validate(Validators::CoverValidator, image: "cover.jpg")

    assert result[:warnings].any? { |w| w.include?("very large") }
  end

  def test_cover_only_in_source_dir
    # Image exists in podcast_dir (source) but not in output_dir (episodes parent)
    File.write(File.join(@podcast_dir, "cover.jpg"), "x" * 50_000)
    # Episodes dir is podcast_dir/episodes, so output_dir = podcast_dir
    # Need a separate output_dir for this test
    output_dir = File.join(@tmpdir, "output")
    episodes_dir = File.join(output_dir, "episodes")
    FileUtils.mkdir_p(episodes_dir)

    result = validate(Validators::CoverValidator,
      image: "cover.jpg",
      episodes_dir: episodes_dir,
      podcast_dir: @podcast_dir)

    assert result[:warnings].any? { |w| w.include?("only in podcasts/ dir") }
  end

  # --- FeedValidator ---

  def test_feed_zero_items
    create_mp3("mypod-2026-01-15.mp3", 1000)
    File.write(@feed_path, "<rss><channel></channel></rss>")
    result = validate(Validators::FeedValidator)

    assert result[:warnings].any? { |w| w.include?("no episodes") }
  end

  def test_feed_multi_language_missing
    create_mp3("mypod-2026-01-15.mp3", 1000)
    write_feed(1)
    result = validate(Validators::FeedValidator,
      languages: [{ "code" => "en" }, { "code" => "es" }])

    assert result[:warnings].any? { |w| w.include?("feed-es.xml") }
  end

  def test_feed_multi_language_present
    create_mp3("mypod-2026-01-15.mp3", 1000)
    write_feed(1)
    File.write(@feed_path.sub(/\.xml$/, "-es.xml"), "<rss><channel></channel></rss>")
    result = validate(Validators::FeedValidator,
      languages: [{ "code" => "en" }, { "code" => "es" }])

    refute result[:warnings].any? { |w| w.include?("feed-es.xml") }
  end

  # --- GuidelinesValidator ---

  def test_guidelines_queue_valid_format
    write_guidelines("## Format\nfoo\n## Tone\nbar\n## Topics\nbaz")
    File.write(@queue_path, { "topics" => ["AI", "Crypto"] }.to_yaml)
    result = validate(Validators::GuidelinesValidator, type: "news")

    refute result[:warnings].any? { |w| w.include?("queue.yml") }
  end

  def test_guidelines_queue_unexpected_format
    write_guidelines("## Format\nfoo\n## Tone\nbar\n## Topics\nbaz")
    File.write(@queue_path, "just a string".to_yaml)
    result = validate(Validators::GuidelinesValidator, type: "news")

    assert result[:warnings].any? { |w| w.include?("unexpected format") }
  end

  def test_guidelines_queue_parse_error
    write_guidelines("## Format\nfoo\n## Tone\nbar\n## Topics\nbaz")
    File.write(@queue_path, "---\n: bad:\n  - [invalid\n")
    result = validate(Validators::GuidelinesValidator, type: "news")

    assert result[:warnings].any? { |w| w.include?("parse error") }
  end

  def test_guidelines_select_is_not_unrecognized_source
    write_guidelines("## Format\nfoo\n## Tone\nbar")
    result = validate(Validators::GuidelinesValidator,
      sources: { "rss" => ["https://example.com/feed"], "select" => "weights" })

    refute result[:warnings].any? { |w| w.include?("unrecognized source") }
  end

  # --- HistoryValidator ---

  def test_history_count_mismatch
    create_mp3("mypod-2026-01-15.mp3", 1000)
    create_mp3("mypod-2026-01-16.mp3", 1000)
    File.write(@history_path, [
      { "date" => "2026-01-15", "title" => "Ep1", "topics" => ["AI"] }
    ].to_yaml)
    result = validate(Validators::HistoryValidator)

    assert result[:warnings].any? { |w| w.include?("differs from episode count") }
  end

  def test_history_no_episodes_dir_still_passes
    FileUtils.rm_rf(@episodes_dir)
    File.write(@history_path, [
      { "date" => "2026-01-15", "title" => "Ep1", "topics" => ["AI"] }
    ].to_yaml)
    result = validate(Validators::HistoryValidator)

    assert result[:passes].any? { |p| p.include?("1 entries") }
    refute result[:warnings].any? { |w| w.include?("differs") }
  end

  # --- ImageConfigValidator ---

  def test_image_config_auto_base_image_skipped
    result = validate(Validators::ImageConfigValidator,
      cover_base_image: :auto, sources: {})

    assert result[:passes].any? { |p| p.include?("no base_image") }
  end

  def test_image_config_per_feed_exists
    img = File.join(@tmpdir, "feed_cover.png")
    File.write(img, "image")
    result = validate(Validators::ImageConfigValidator,
      cover_base_image: nil,
      sources: { "rss" => [{ base_image: img, url: "https://example.com/feed" }] })

    assert result[:passes].any? { |p| p.include?("per-feed base_image exists") }
  end

  def test_image_config_per_feed_missing
    result = validate(Validators::ImageConfigValidator,
      cover_base_image: nil,
      sources: { "rss" => [{ base_image: "/nonexistent.png", url: "https://example.com/feed" }] })

    assert result[:errors].any? { |e| e.include?("per-feed base_image not found") }
  end

  # --- LanguagePipelineValidator ---

  def test_language_pipeline_no_engines
    result = validate(Validators::LanguagePipelineValidator,
      transcription_engines: [], lingq_config: nil)

    assert result[:warnings].any? { |w| w.include?("no transcription engines") }
  end

  def test_language_pipeline_engines_present
    result = validate(Validators::LanguagePipelineValidator,
      transcription_engines: ["openai"], lingq_config: nil)

    assert result[:passes].any? { |p| p.include?("openai") }
  end

  def test_language_pipeline_multi_engine_groq_missing_tails
    result = validate(Validators::LanguagePipelineValidator,
      transcription_engines: ["openai", "groq"], lingq_config: nil)

    assert result[:warnings].any? { |w| w.include?("tails/ directory missing") }
  end

  def test_language_pipeline_multi_engine_groq_tails_present
    tails_dir = File.join(@podcast_dir, "tails")
    FileUtils.mkdir_p(tails_dir)
    result = validate(Validators::LanguagePipelineValidator,
      transcription_engines: ["openai", "groq"], lingq_config: nil)

    refute result[:warnings].any? { |w| w.include?("tails/") }
  end

  def test_language_pipeline_lingq_image_missing
    result = validate(Validators::LanguagePipelineValidator,
      transcription_engines: ["openai"],
      lingq_config: { image: "/nonexistent.png", base_image: nil })

    assert result[:warnings].any? { |w| w.include?("LingQ: image file not found") }
  end

  def test_language_pipeline_lingq_base_image_missing
    result = validate(Validators::LanguagePipelineValidator,
      transcription_engines: ["openai"],
      lingq_config: { image: nil, base_image: "/nonexistent.png" })

    assert result[:warnings].any? { |w| w.include?("LingQ: base_image file not found") }
  end

  # --- NewsPipelineValidator ---

  def test_news_pipeline_queue_present
    File.write(@queue_path, { "topics" => ["AI"] }.to_yaml)
    result = validate(Validators::NewsPipelineValidator)

    assert result[:passes].any? { |p| p.include?("queue.yml present") }
  end

  def test_news_pipeline_queue_missing
    result = validate(Validators::NewsPipelineValidator,
      queue_path: "/nonexistent.yml")

    assert result[:warnings].any? { |w| w.include?("queue.yml not found") }
  end

  # --- OrphansValidator ---

  def test_orphans_no_episodes_dir
    FileUtils.rm_rf(@episodes_dir)
    result = validate(Validators::OrphansValidator)

    assert_empty result[:warnings]
    assert_empty result[:errors]
  end

  def test_orphans_no_orphans
    create_mp3("mypod-2026-01-15.mp3", 1000)
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_script.md"), "text")
    result = validate(Validators::OrphansValidator)

    assert_empty result[:warnings]
  end

  def test_orphans_transcript_without_mp3
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "text")
    result = validate(Validators::OrphansValidator)

    assert result[:warnings].any? { |w| w.include?("transcript/script") && w.include?("without matching MP3") }
  end

  def test_orphans_stale_concat_files
    create_mp3("mypod-2026-01-15.mp3", 1000)
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_concat.mp3"), "data")
    result = validate(Validators::OrphansValidator)

    assert result[:warnings].any? { |w| w.include?("_concat") }
  end

  # --- TranscriptsValidator ---

  def test_transcripts_full_coverage
    create_mp3("mypod-2026-01-15.mp3", 1000)
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_script.md"), "text")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_script.html"), "<p>text</p>")
    result = validate(Validators::TranscriptsValidator)

    assert result[:passes].any? { |p| p.include?("1/1") }
    refute result[:warnings].any? { |w| w.include?("missing HTML") }
  end

  def test_transcripts_empty_dir
    result = validate(Validators::TranscriptsValidator)

    assert_empty result[:passes]
    assert_empty result[:warnings]
    assert_empty result[:errors]
  end

  def test_transcripts_transcript_variant
    create_mp3("mypod-2026-01-15.mp3", 1000)
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.md"), "text")
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_transcript.html"), "<p>text</p>")
    result = validate(Validators::TranscriptsValidator)

    assert result[:passes].any? { |p| p.include?("1/1") }
  end

  # --- PodcastValidator orchestrator ---

  def test_podcast_validator_result_ok_with_no_errors
    result = PodcastValidator::Result.new(passes: ["ok"], warnings: ["warn"], errors: [])
    assert result.ok?
  end

  def test_podcast_validator_result_not_ok_with_errors
    result = PodcastValidator::Result.new(passes: [], warnings: [], errors: ["bad"])
    refute result.ok?
  end

  def test_podcast_validator_result_clean_with_nothing
    result = PodcastValidator::Result.new(passes: ["ok"], warnings: [], errors: [])
    assert result.clean?
  end

  def test_podcast_validator_result_not_clean_with_warnings
    result = PodcastValidator::Result.new(passes: [], warnings: ["warn"], errors: [])
    refute result.clean?
  end

  def test_podcast_validator_class_method
    write_guidelines("## Format\nfoo\n## Tone\nbar\n## Topics\nbaz")
    File.write(@queue_path, { "topics" => ["AI"] }.to_yaml)
    result = PodcastValidator.validate(stub_config(type: "news"))

    assert_kind_of PodcastValidator::Result, result
    assert result.ok?
  end

  def test_podcast_validator_selects_language_pipeline
    write_guidelines("## Format\nfoo\n## Tone\nbar")
    config = stub_config(type: "language", transcription_engines: ["openai"])
    result = PodcastValidator.validate(config)

    # Should include language pipeline pass, not news pipeline
    assert result.passes.any? { |p| p.include?("engines") }
  end

  def test_podcast_validator_selects_news_pipeline
    write_guidelines("## Format\nfoo\n## Tone\nbar\n## Topics\nbaz")
    File.write(@queue_path, { "topics" => ["AI"] }.to_yaml)
    config = stub_config(type: "news")
    result = PodcastValidator.validate(config)

    assert result.passes.any? { |p| p.include?("queue.yml present") }
  end

  private

  def create_mp3(name, size)
    File.write(File.join(@episodes_dir, name), "x" * size)
  end

  def write_guidelines(content)
    File.write(@guidelines_path, content)
  end

  def write_feed(item_count)
    items = (1..item_count).map { |i| "<item><title>Ep #{i}</title></item>" }.join
    File.write(@feed_path, "<rss><channel>#{items}</channel></rss>")
  end

  StubConfig = Struct.new(
    :name, :type, :guidelines_path, :guidelines, :episodes_dir,
    :feed_path, :history_path, :queue_path, :podcast_dir,
    :base_url, :image, :languages, :sources, :cover_base_image,
    :transcription_engines, :lingq_config,
    keyword_init: true
  ) do
    def parser_warnings = []
  end

  def stub_config(**overrides)
    defaults = {
      name: "mypod",
      type: "news",
      guidelines_path: @guidelines_path,
      guidelines: (File.read(@guidelines_path) rescue ""),
      episodes_dir: @episodes_dir,
      feed_path: @feed_path,
      history_path: @history_path,
      queue_path: @queue_path,
      podcast_dir: @podcast_dir,
      base_url: nil,
      image: nil,
      languages: [{ "code" => "en" }],
      sources: {},
      cover_base_image: nil,
      transcription_engines: [],
      lingq_config: nil
    }
    StubConfig.new(**defaults.merge(overrides))
  end

  def validate(klass, **config_overrides)
    klass.new(stub_config(**config_overrides)).validate
  end
end
