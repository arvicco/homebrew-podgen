# frozen_string_literal: true

require_relative "../test_helper"
require "cover_resolver"

class TestCoverResolver < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("cover_test")
    @episodes_dir = File.join(@dir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- find_episode_cover ---

  def test_find_episode_cover_returns_matching_file
    cover = File.join(@episodes_dir, "ep-2026-01-01_cover.jpg")
    File.write(cover, "fake image")

    result = CoverResolver.find_episode_cover(@episodes_dir, "ep-2026-01-01")
    assert_equal cover, result
  end

  def test_find_episode_cover_matches_any_extension
    cover = File.join(@episodes_dir, "ep-2026-01-01_cover.png")
    File.write(cover, "fake image")

    result = CoverResolver.find_episode_cover(@episodes_dir, "ep-2026-01-01")
    assert_equal cover, result
  end

  def test_find_episode_cover_returns_nil_when_missing
    result = CoverResolver.find_episode_cover(@episodes_dir, "ep-2026-01-01")
    assert_nil result
  end

  def test_find_episode_cover_does_not_match_partial_basename
    File.write(File.join(@episodes_dir, "ep-2026-01-01-extra_cover.jpg"), "img")

    result = CoverResolver.find_episode_cover(@episodes_dir, "ep-2026-01-01")
    assert_nil result
  end

  # --- generate ---

  def test_generate_calls_cover_agent
    base_image = File.join(@dir, "base.jpg")
    File.write(base_image, "fake base image")

    called_with = nil
    fake_agent_class = Class.new do
      define_method(:initialize) { |**_| }
      define_method(:generate) do |**kwargs|
        called_with = kwargs
        kwargs[:output_path]
      end
    end

    result = CoverResolver.generate(
      title: "Test Title",
      base_image: base_image,
      options: { font_size: 120 },
      agent_class: fake_agent_class
    )

    assert called_with, "CoverAgent.generate should have been called"
    assert_equal "Test Title", called_with[:title]
    assert_equal base_image, called_with[:base_image]
    assert_equal({ font_size: 120 }, called_with[:options])
    assert result.end_with?(".jpg")
  end

  def test_generate_returns_nil_when_base_image_missing
    result = CoverResolver.generate(
      title: "Title",
      base_image: "/nonexistent/path.jpg"
    )

    assert_nil result
  end

  def test_generate_returns_nil_when_base_image_nil
    result = CoverResolver.generate(title: "Title", base_image: nil)
    assert_nil result
  end

  # --- cleanup ---

  def test_cleanup_deletes_temp_file
    path = File.join(Dir.tmpdir, "podgen_test_cleanup_#{Process.pid}.jpg")
    File.write(path, "tmp")

    CoverResolver.cleanup(path)
    refute File.exist?(path)
  end

  def test_cleanup_ignores_non_temp_files
    non_tmp = File.join(Dir.home, "podgen_test_cover_#{Process.pid}.jpg")
    File.write(non_tmp, "keep")

    CoverResolver.cleanup(non_tmp)
    assert File.exist?(non_tmp), "Should not delete files outside tmpdir"
  ensure
    File.delete(non_tmp) if non_tmp && File.exist?(non_tmp)
  end

  def test_cleanup_ignores_nil
    CoverResolver.cleanup(nil) # should not raise
  end
end
