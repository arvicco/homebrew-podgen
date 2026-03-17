# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "cli/validate_command"
require "podcast_validator"

class TestValidateCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_validate_test")
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

  # --- format_size ---

  def test_format_size_bytes
    v = build_validator
    assert_equal "500 B", v.send(:format_size, 500)
  end

  def test_format_size_kilobytes
    v = build_validator
    assert_equal "10 KB", v.send(:format_size, 10_000)
  end

  def test_format_size_megabytes
    v = build_validator
    assert_equal "1.5 MB", v.send(:format_size, 1_500_000)
  end

  def test_format_size_gigabytes
    v = build_validator
    assert_equal "2.3 GB", v.send(:format_size, 2_300_000_000)
  end

  # --- check_guidelines ---

  def test_check_guidelines_missing_file
    config = stub_config(guidelines_path: "/nonexistent")
    passes, warnings, errors = run_check(:check_guidelines, config)

    assert_empty passes
    assert errors.any? { |e| e.include?("not found") }
  end

  def test_check_guidelines_all_sections_present_news
    write_guidelines("## Format\nfoo\n## Tone\nbar\n## Topics\nbaz")
    config = stub_config(type: "news")
    passes, warnings, errors = run_check(:check_guidelines, config)

    assert_empty errors
    assert passes.any? { |p| p.include?("all required sections") }
  end

  def test_check_guidelines_missing_topics_for_news
    write_guidelines("## Format\nfoo\n## Tone\nbar")
    config = stub_config(type: "news")
    _, _, errors = run_check(:check_guidelines, config)

    assert errors.any? { |e| e.include?("Topics") }
  end

  def test_check_guidelines_language_type_no_topics_required
    write_guidelines("## Format\nfoo\n## Tone\nbar")
    config = stub_config(type: "language")
    passes, _, errors = run_check(:check_guidelines, config)

    assert_empty errors
    assert passes.any? { |p| p.include?("all required sections") }
  end

  def test_check_guidelines_unrecognized_source
    write_guidelines("## Format\nfoo\n## Tone\nbar")
    config = stub_config(sources: { "exa" => true, "unknown_source" => true })
    _, warnings, _ = run_check(:check_guidelines, config)

    assert warnings.any? { |w| w.include?("unrecognized source") && w.include?("unknown_source") }
  end

  # --- check_episodes ---

  def test_check_episodes_no_directory
    config = stub_config(episodes_dir: "/nonexistent")
    _, warnings, _ = run_check(:check_episodes, config)

    assert warnings.any? { |w| w.include?("directory not found") }
  end

  def test_check_episodes_no_mp3s
    config = stub_config
    _, warnings, _ = run_check(:check_episodes, config)

    assert warnings.any? { |w| w.include?("no MP3 files") }
  end

  def test_check_episodes_with_mp3s
    create_mp3("mypod-2026-01-15.mp3", 10_000)
    config = stub_config
    passes, _, errors = run_check(:check_episodes, config)

    assert_empty errors
    assert passes.any? { |p| p.include?("1 MP3") }
  end

  def test_check_episodes_zero_byte_mp3
    create_mp3("mypod-2026-01-15.mp3", 0)
    config = stub_config
    _, _, errors = run_check(:check_episodes, config)

    assert errors.any? { |e| e.include?("zero-byte") }
  end

  def test_check_episodes_bad_naming
    create_mp3("weird-file.mp3", 1000)
    config = stub_config
    _, warnings, _ = run_check(:check_episodes, config)

    assert warnings.any? { |w| w.include?("unexpected naming") }
  end

  # --- check_transcripts ---

  def test_check_transcripts_all_present
    create_mp3("mypod-2026-01-15.mp3", 1000)
    File.write(File.join(@episodes_dir, "mypod-2026-01-15_script.md"), "# Title\n\nText")
    config = stub_config
    passes, warnings, _ = run_check(:check_transcripts, config)

    assert passes.any? { |p| p.include?("1/1") }
    # Still warns about missing HTML
    assert warnings.any? { |w| w.include?("missing HTML") }
  end

  def test_check_transcripts_missing_markdown
    create_mp3("mypod-2026-01-15.mp3", 1000)
    config = stub_config
    _, warnings, _ = run_check(:check_transcripts, config)

    assert warnings.any? { |w| w.include?("missing transcript/script") }
  end

  # --- check_feed ---

  def test_check_feed_missing
    config = stub_config(feed_path: "/nonexistent.xml")
    _, warnings, _ = run_check(:check_feed, config)

    assert warnings.any? { |w| w.include?("not found") }
  end

  def test_check_feed_valid_xml
    create_mp3("mypod-2026-01-15.mp3", 1000)
    write_feed(1)
    config = stub_config
    passes, _, errors = run_check(:check_feed, config)

    assert_empty errors
    assert passes.any? { |p| p.include?("well-formed XML") }
  end

  def test_check_feed_invalid_xml
    File.write(@feed_path, "not valid xml <<>>")
    config = stub_config
    _, _, errors = run_check(:check_feed, config)

    assert errors.any? { |e| e.include?("XML parse error") }
  end

  def test_check_feed_stale_count
    create_mp3("mypod-2026-01-15.mp3", 1000)
    create_mp3("mypod-2026-01-16.mp3", 1000)
    write_feed(1) # Only 1 item in feed, but 2 MP3s
    config = stub_config
    _, warnings, _ = run_check(:check_feed, config)

    assert warnings.any? { |w| w.include?("stale feed") }
  end

  # --- check_cover ---

  def test_check_cover_no_image_configured
    config = stub_config(image: nil)
    _, warnings, _ = run_check(:check_cover, config)

    assert warnings.any? { |w| w.include?("no image configured") }
  end

  def test_check_cover_exists_good_size
    File.write(File.join(@podcast_dir, "cover.jpg"), "x" * 50_000)
    config = stub_config(image: "cover.jpg")
    passes, _, _ = run_check(:check_cover, config)

    assert passes.any? { |p| p.include?("cover.jpg") }
  end

  def test_check_cover_too_small
    File.write(File.join(@podcast_dir, "cover.jpg"), "x" * 100)
    config = stub_config(image: "cover.jpg")
    _, warnings, _ = run_check(:check_cover, config)

    assert warnings.any? { |w| w.include?("very small") }
  end

  def test_check_cover_not_found
    config = stub_config(image: "missing.jpg")
    _, _, errors = run_check(:check_cover, config)

    assert errors.any? { |e| e.include?("not found") }
  end

  # --- check_base_url ---

  def test_check_base_url_not_configured
    config = stub_config(base_url: nil)
    _, warnings, _ = run_check(:check_base_url, config)

    assert warnings.any? { |w| w.include?("not configured") }
  end

  def test_check_base_url_valid
    config = stub_config(base_url: "https://example.com/pod")
    passes, _, _ = run_check(:check_base_url, config)

    assert passes.any? { |p| p.include?("https://example.com/pod") }
  end

  def test_check_base_url_invalid
    config = stub_config(base_url: "ftp://bad")
    _, _, errors = run_check(:check_base_url, config)

    assert errors.any? { |e| e.include?("does not start with http") }
  end

  # --- check_history ---

  def test_check_history_missing
    config = stub_config(history_path: "/nonexistent.yml")
    _, warnings, _ = run_check(:check_history, config)

    assert warnings.any? { |w| w.include?("not found") }
  end

  def test_check_history_valid
    create_mp3("mypod-2026-01-15.mp3", 1000)
    File.write(@history_path, [{ "date" => "2026-01-15", "title" => "Test", "topics" => ["AI"] }].to_yaml)
    config = stub_config
    passes, _, errors = run_check(:check_history, config)

    assert_empty errors
    assert passes.any? { |p| p.include?("1 entries") }
  end

  def test_check_history_bad_format
    File.write(@history_path, { "not" => "an array" }.to_yaml)
    config = stub_config
    _, _, errors = run_check(:check_history, config)

    assert errors.any? { |e| e.include?("unexpected format") }
  end

  def test_check_history_entries_missing_fields
    File.write(@history_path, [{ "date" => "2026-01-15" }].to_yaml)
    config = stub_config
    _, warnings, _ = run_check(:check_history, config)

    assert warnings.any? { |w| w.include?("missing date/title/topics") }
  end

  # --- check_image_config ---

  def test_check_image_config_no_base_image
    config = stub_config(cover_base_image: nil, sources: {})
    passes, _, _ = run_check(:check_image_config, config)

    assert passes.any? { |p| p.include?("no base_image") }
  end

  def test_check_image_config_base_image_exists
    img = File.join(@tmpdir, "base.png")
    File.write(img, "image")
    config = stub_config(cover_base_image: img, sources: {})
    passes, _, errors = run_check(:check_image_config, config)

    assert_empty errors
    assert passes.any? { |p| p.include?("base_image exists") }
  end

  def test_check_image_config_base_image_missing
    config = stub_config(cover_base_image: "/nonexistent.png", sources: {})
    _, _, errors = run_check(:check_image_config, config)

    assert errors.any? { |e| e.include?("base_image not found") }
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

  StubValidateConfig = Struct.new(
    :name, :type, :guidelines_path, :guidelines, :episodes_dir,
    :feed_path, :history_path, :queue_path, :podcast_dir,
    :base_url, :image, :languages, :sources, :cover_base_image,
    :transcription_engines, :lingq_config,
    keyword_init: true
  )

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
    StubValidateConfig.new(**defaults.merge(overrides))
  end

  def build_validator(config = nil)
    PodcastValidator.new(config || stub_config)
  end

  def run_check(method, config)
    validator = PodcastValidator.new(config)
    validator.send(method)
    [validator.instance_variable_get(:@passes),
     validator.instance_variable_get(:@warnings),
     validator.instance_variable_get(:@errors)]
  end
end
