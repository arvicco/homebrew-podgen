# frozen_string_literal: true

require_relative "../test_helper"
require "fileutils"
require "episode_cover_resolver"

# Pins the 8-step cover priority chain:
#   cli image > feed image (incl. auto) > cli base > feed base >
#   RSS image > config generation > thumbnail > nil
class TestEpisodeCoverResolver < Minitest::Test
  class CaptureLogger
    attr_reader :messages

    def initialize = @messages = []

    def log(msg) = @messages << msg
  end

  CoverStubConfig = Struct.new(:cover_base_image, :cover_options, :cover_generation_enabled, keyword_init: true) do
    def cover_generation_enabled? = cover_generation_enabled

    def auto_cover_config = {}
  end

  def setup
    @tmpdir = Dir.mktmpdir("podgen_cover_resolver_test")
    @logger = CaptureLogger.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- step 1: --image ---

  def test_cli_image_path
    image_path = File.join(@tmpdir, "custom.png")
    FileUtils.touch(image_path)

    path, desc = build_resolver(cli_image: image_path).resolve("Title")

    assert_equal File.expand_path(image_path), path
    assert_includes desc, "--image"
  end

  def test_cli_image_thumb_uses_youtube_thumbnail
    path, desc = build_resolver(cli_image: "thumb", youtube_thumbnail: "/tmp/thumb.jpg").resolve("Title")

    assert_equal "/tmp/thumb.jpg", path
    assert_includes desc, "thumb"
  end

  def test_cli_image_beats_feed_image
    image_path = File.join(@tmpdir, "cli.png")
    FileUtils.touch(image_path)

    path, desc = build_resolver(cli_image: image_path, feed_image: "/tmp/feed_cover.jpg").resolve("Title")

    assert_equal File.expand_path(image_path), path
    assert_includes desc, "--image"
  end

  # --- step 2: feed image ---

  def test_feed_image_literal_path
    path, desc = build_resolver(feed_image: "/tmp/feed_cover.jpg").resolve("Title")

    assert_equal "/tmp/feed_cover.jpg", path
    assert_includes desc, "feed image"
  end

  def test_feed_image_thumb_uses_youtube_thumbnail
    path, desc = build_resolver(feed_image: "thumb", youtube_thumbnail: "/tmp/thumb.jpg").resolve("Title")

    assert_equal "/tmp/thumb.jpg", path
    assert_includes desc, "thumb"
  end

  def test_image_none_falls_to_thumbnail
    path, desc = build_resolver(image_none: true, youtube_thumbnail: "/tmp/thumb.jpg").resolve("Title")

    assert_equal "/tmp/thumb.jpg", path
    assert_includes desc, "none"
  end

  # --- step 2a: auto ---

  def test_cli_image_auto_returns_winner_path
    # Regression: --image auto used to be misread as a literal file path
    # (File.expand_path("auto") → /Users/.../auto), crashing ImageMagick.
    resolver = build_resolver(cli_image: "auto")
    winner = "/tmp/podgen_auto_winner.jpg"
    resolver.define_singleton_method(:try_auto_cover) { |_title| winner }

    path, desc = resolver.resolve("Title")

    assert_equal winner, path
    assert_includes desc, "--image auto"
    refute_match(%r{/auto\z}, path.to_s, "must not treat 'auto' as a relative path")
  end

  def test_cli_image_auto_falls_through_when_no_winner
    resolver = build_resolver(cli_image: "auto", youtube_thumbnail: "/tmp/thumb.jpg")
    resolver.define_singleton_method(:try_auto_cover) { |_title| nil }

    path, = resolver.resolve("Title")

    assert_equal "/tmp/thumb.jpg", path
  end

  def test_cli_image_auto_falls_through_to_rss_image_when_no_winner
    resolver = build_resolver(cli_image: "auto", rss_episode_image: "/tmp/rss_cover.jpg")
    resolver.define_singleton_method(:try_auto_cover) { |_title| nil }

    path, desc = resolver.resolve("Title")

    assert_equal "/tmp/rss_cover.jpg", path
    assert_includes desc, "RSS"
  end

  def test_feed_image_auto_returns_winner
    resolver = build_resolver(feed_image: "auto")
    resolver.define_singleton_method(:try_auto_cover) { |_title| "/tmp/auto_winner.jpg" }

    path, desc = resolver.resolve("Title")

    assert_equal "/tmp/auto_winner.jpg", path
    assert_includes desc, "feed image: auto"
  end

  # --- steps 3-4: base image overlays ---

  def test_cli_base_image_generates_overlay
    resolver = build_resolver(cli_base_image: "/tmp/base.png")
    resolver.define_singleton_method(:generate_cover_image) { |_t, _b = nil| "/tmp/generated.jpg" }

    path, desc = resolver.resolve("Title")

    assert_equal "/tmp/generated.jpg", path
    assert_includes desc, "--base-image"
  end

  def test_cli_base_image_beats_feed_base_image
    resolver = build_resolver(cli_base_image: "/tmp/cli_base.png", feed_base_image: "/tmp/feed_base.png")
    bases = []
    resolver.define_singleton_method(:generate_cover_image) do |_t, b = nil|
      bases << b
      "/tmp/generated.jpg"
    end

    _path, desc = resolver.resolve("Title")

    assert_includes desc, "--base-image"
    assert_equal [File.expand_path("/tmp/cli_base.png")], bases
  end

  def test_feed_base_image_beats_rss_image
    resolver = build_resolver(feed_base_image: "/tmp/base.jpg", rss_episode_image: "/tmp/rss_cover.jpg")

    path, desc = resolver.resolve("Title")

    # feed base_image triggers generate_cover_image which fails on fake path,
    # but the point is it did NOT return the RSS image
    refute_equal "/tmp/rss_cover.jpg", path
    assert_includes desc, "feed base_image"
  end

  def test_base_image_generation_failure_falls_to_thumbnail
    resolver = build_resolver(cli_base_image: "/tmp/base.png", youtube_thumbnail: "/tmp/thumb.jpg")
    resolver.define_singleton_method(:generate_cover_image) { |_t, _b = nil| nil }

    path, = resolver.resolve("Title")

    assert_equal "/tmp/thumb.jpg", path
  end

  # --- steps 5-8: rss, config generation, thumbnail, nil ---

  def test_rss_episode_image
    path, desc = build_resolver(rss_episode_image: "/tmp/rss_cover.jpg").resolve("Title")

    assert_equal "/tmp/rss_cover.jpg", path
    assert_includes desc, "RSS"
  end

  def test_rss_image_beats_config_generation
    path, desc = build_resolver(rss_episode_image: "/tmp/rss_cover.jpg", cover_generation_enabled: true)
      .resolve("Title")

    assert_equal "/tmp/rss_cover.jpg", path
    assert_includes desc, "RSS"
  end

  def test_config_generation_when_enabled
    resolver = build_resolver(cover_generation_enabled: true)
    resolver.define_singleton_method(:generate_cover_image) { |_t, _b = nil| "/tmp/config_generated.jpg" }

    path, desc = resolver.resolve("Title")

    assert_equal "/tmp/config_generated.jpg", path
    assert_includes desc, "config base_image"
  end

  def test_returns_nil_when_no_source_resolves
    path, = build_resolver.resolve("Title")

    assert_nil path
  end

  def test_warns_when_configured_base_image_missing
    path, = build_resolver(cover_base_image: "/nonexistent/base.png").resolve("Title")

    assert_nil path
    assert(@logger.messages.any? { |m| m.include?("base_image configured but not found") },
      "missing configured base_image must log a warning")
  end

  # --- overlay option merging ---

  def test_generate_merges_feed_overlay_opts_over_config
    base_path = File.join(@tmpdir, "base.png")
    FileUtils.touch(base_path)

    resolver = build_resolver(
      cover_base_image: base_path,
      cover_generation_enabled: true,
      cover_options: {font: "Helvetica", font_color: "black", font_size: 24, gravity: "Center"},
      feed_cover_opts: {
        font_size: 48,    # overrides config
        gravity: "South", # overrides config
        x_offset: 10      # new key, no config equivalent
      }
    )

    captured = nil
    CoverResolver.stub(:generate, ->(**kw) {
      captured = kw
      "/tmp/cover.jpg"
    }) do
      resolver.send(:generate_cover_image, "Title", base_path)
    end

    refute_nil captured, "CoverResolver.generate should have been called"
    opts = captured[:options]
    assert_equal "Helvetica", opts[:font], "unspecified key falls back to config"
    assert_equal "black", opts[:font_color], "unspecified key falls back to config"
    assert_equal 48, opts[:font_size], "feed override wins for font_size"
    assert_equal "South", opts[:gravity], "feed override wins for gravity"
    assert_equal 10, opts[:x_offset], "new feed key is included"
  end

  def test_generate_uses_config_opts_when_no_feed_opts
    base_path = File.join(@tmpdir, "base.png")
    FileUtils.touch(base_path)

    resolver = build_resolver(
      cover_base_image: base_path,
      cover_generation_enabled: true,
      cover_options: {font: "Helvetica", font_size: 24}
    )

    captured = nil
    CoverResolver.stub(:generate, ->(**kw) {
      captured = kw
      "/tmp/cover.jpg"
    }) do
      resolver.send(:generate_cover_image, "Title", base_path)
    end

    assert_equal({font: "Helvetica", font_size: 24}, captured[:options])
  end

  private

  def build_resolver(cover_base_image: nil, cover_options: {}, cover_generation_enabled: false, **kwargs)
    config = CoverStubConfig.new(
      cover_base_image: cover_base_image,
      cover_options: cover_options,
      cover_generation_enabled: cover_generation_enabled
    )
    EpisodeCoverResolver.new(
      config: config,
      logger: @logger,
      staging_dir: @tmpdir,
      base_name: "test-2026-03-10",
      **kwargs
    )
  end
end
