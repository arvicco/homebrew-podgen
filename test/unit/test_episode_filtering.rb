# frozen_string_literal: true

require_relative "../test_helper"
require "episode_filtering"

class TestEpisodeFiltering < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_ep_filter")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- matches_language? ---

  def test_matches_language_english_no_suffix
    assert EpisodeFiltering.matches_language?("show-2026-01-15", "en")
  end

  def test_matches_language_english_rejects_suffixed
    refute EpisodeFiltering.matches_language?("show-2026-01-15-es", "en")
    refute EpisodeFiltering.matches_language?("show-2026-01-15-fr", "en")
  end

  def test_matches_language_non_english_matches_suffix
    assert EpisodeFiltering.matches_language?("show-2026-01-15-es", "es")
  end

  def test_matches_language_non_english_rejects_wrong_suffix
    refute EpisodeFiltering.matches_language?("show-2026-01-15-fr", "es")
  end

  def test_matches_language_non_english_rejects_no_suffix
    refute EpisodeFiltering.matches_language?("show-2026-01-15", "es")
  end

  def test_matches_language_english_with_day_suffix
    assert EpisodeFiltering.matches_language?("show-2026-01-15a", "en")
  end

  # --- all_episodes ---

  def test_all_episodes_returns_mp3s
    create_file("show-2026-01-15.mp3")
    create_file("show-2026-01-16.mp3")

    result = EpisodeFiltering.all_episodes(@episodes_dir)
    assert_equal 2, result.length
  end

  def test_all_episodes_excludes_concat
    create_file("show-2026-01-15.mp3")
    create_file("show-2026-01-15_concat.mp3")

    result = EpisodeFiltering.all_episodes(@episodes_dir)
    assert_equal 1, result.length
    refute result.first.include?("_concat")
  end

  def test_all_episodes_returns_empty_for_missing_dir
    assert_equal [], EpisodeFiltering.all_episodes("/nonexistent/dir")
  end

  def test_all_episodes_returns_empty_for_empty_dir
    assert_equal [], EpisodeFiltering.all_episodes(@episodes_dir)
  end

  # --- english_episodes ---

  def test_english_episodes_excludes_language_suffixed
    create_file("show-2026-01-15.mp3")
    create_file("show-2026-01-15-es.mp3")
    create_file("show-2026-01-15-fr.mp3")

    result = EpisodeFiltering.english_episodes(@episodes_dir)
    assert_equal 1, result.length
    assert_includes result.first, "show-2026-01-15.mp3"
  end

  def test_english_episodes_excludes_concat_and_language
    create_file("show-2026-01-15.mp3")
    create_file("show-2026-01-15_concat.mp3")
    create_file("show-2026-01-15-es.mp3")

    result = EpisodeFiltering.english_episodes(@episodes_dir)
    assert_equal 1, result.length
  end

  def test_english_episodes_keeps_day_suffix
    create_file("show-2026-01-15.mp3")
    create_file("show-2026-01-15a.mp3")

    result = EpisodeFiltering.english_episodes(@episodes_dir)
    assert_equal 2, result.length
  end

  # --- episodes_for_language ---

  def test_episodes_for_language_english
    create_file("show-2026-01-15.mp3")
    create_file("show-2026-01-15-es.mp3")

    result = EpisodeFiltering.episodes_for_language(@episodes_dir, "en")
    assert_equal 1, result.length
    assert_includes result.first, "show-2026-01-15.mp3"
  end

  def test_episodes_for_language_non_english
    create_file("show-2026-01-15.mp3")
    create_file("show-2026-01-15-es.mp3")
    create_file("show-2026-01-15-fr.mp3")

    result = EpisodeFiltering.episodes_for_language(@episodes_dir, "es")
    assert_equal 1, result.length
    assert_includes result.first, "-es.mp3"
  end

  def test_episodes_for_language_excludes_concat
    create_file("show-2026-01-15-es.mp3")
    create_file("show-2026-01-15-es_concat.mp3")

    result = EpisodeFiltering.episodes_for_language(@episodes_dir, "es")
    assert_equal 1, result.length
  end

  private

  def create_file(name, content = "x")
    File.write(File.join(@episodes_dir, name), content)
  end
end
