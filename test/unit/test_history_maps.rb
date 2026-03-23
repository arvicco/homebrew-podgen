# frozen_string_literal: true

require_relative "../test_helper"
require "history_maps"

class TestHistoryMaps < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_history_maps_test")
    @episodes_dir = File.join(@tmpdir, "test_pod", "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- No history ---

  def test_returns_empty_maps_when_no_file
    title, timestamp, duration = HistoryMaps.build(
      history_path: nil,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir
    )
    assert_equal({}, title)
    assert_equal({}, timestamp)
    assert_equal({}, duration)
  end

  def test_returns_empty_maps_when_file_missing
    title, timestamp, duration = HistoryMaps.build(
      history_path: "/nonexistent/path.yml",
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir
    )
    assert_equal({}, title)
    assert_equal({}, timestamp)
    assert_equal({}, duration)
  end

  def test_returns_empty_maps_for_corrupt_yaml
    path = File.join(@tmpdir, "history.yml")
    File.write(path, "not: valid: yaml: [[[")
    title, _, _ = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir
    )
    assert_equal({}, title)
  end

  # --- Basic mapping ---

  def test_maps_single_episode
    history = [{ "date" => "2026-03-01", "title" => "Episode One", "duration" => 600, "timestamp" => "2026-03-01T06:00:00Z" }]
    path = write_history(history)

    title, timestamp, duration = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir
    )

    assert_equal "Episode One", title["test_pod-2026-03-01.mp3"]
    assert_equal 600, duration["test_pod-2026-03-01.mp3"]
    assert_equal "2026-03-01T06:00:00Z", timestamp["test_pod-2026-03-01.mp3"]
  end

  def test_maps_same_day_episodes_with_suffixes
    history = [
      { "date" => "2026-03-01", "title" => "First" },
      { "date" => "2026-03-01", "title" => "Second" }
    ]
    path = write_history(history)

    title, _, _ = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir
    )

    assert_equal "First", title["test_pod-2026-03-01.mp3"]
    assert_equal "Second", title["test_pod-2026-03-01a.mp3"]
  end

  def test_skips_entries_without_date
    history = [
      { "title" => "No date" },
      { "date" => "2026-03-01", "title" => "Has date" }
    ]
    path = write_history(history)

    title, _, _ = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir
    )

    assert_equal 1, title.size
    assert_equal "Has date", title["test_pod-2026-03-01.mp3"]
  end

  # --- Language mapping ---

  def test_maps_single_language
    history = [{ "date" => "2026-03-01", "title" => "Episode One", "duration" => 600 }]
    path = write_history(history)

    title, _, duration = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir,
      languages: ["es"]
    )

    # English base
    assert_equal "Episode One", title["test_pod-2026-03-01.mp3"]
    # Spanish version falls back to English title
    assert_equal "Episode One", title["test_pod-2026-03-01-es.mp3"]
    assert_equal 600, duration["test_pod-2026-03-01-es.mp3"]
  end

  def test_language_title_from_script_file
    history = [{ "date" => "2026-03-01", "title" => "Episode One" }]
    path = write_history(history)

    # Create a Spanish script file with translated title
    File.write(File.join(@episodes_dir, "test_pod-2026-03-01-es_script.md"), "# Episodio Uno\n\n## Apertura\n\nBienvenidos.\n")

    title, _, _ = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir,
      languages: ["es"]
    )

    assert_equal "Episodio Uno", title["test_pod-2026-03-01-es.mp3"]
  end

  def test_multiple_languages
    history = [{ "date" => "2026-03-01", "title" => "Episode One" }]
    path = write_history(history)

    title, _, _ = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir,
      languages: ["es", "fr"]
    )

    assert_equal "Episode One", title["test_pod-2026-03-01.mp3"]
    assert_equal "Episode One", title["test_pod-2026-03-01-es.mp3"]
    assert_equal "Episode One", title["test_pod-2026-03-01-fr.mp3"]
  end

  def test_english_language_not_duplicated
    history = [{ "date" => "2026-03-01", "title" => "Episode One" }]
    path = write_history(history)

    title, _, _ = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir,
      languages: ["en", "es"]
    )

    # Only base + es, no duplicate "en" suffix
    assert_equal "Episode One", title["test_pod-2026-03-01.mp3"]
    assert_equal "Episode One", title["test_pod-2026-03-01-es.mp3"]
    refute title.key?("test_pod-2026-03-01-en.mp3")
  end

  # --- Basename-based mapping ---

  def test_build_uses_basename_when_present
    history = [
      { "date" => "2026-03-01", "title" => "First", "basename" => "test_pod-2026-03-01" },
      { "date" => "2026-03-01", "title" => "Second", "basename" => "test_pod-2026-03-01a" }
    ]
    path = write_history(history)

    title, _, _ = HistoryMaps.build(
      history_path: path, podcast_name: "test_pod", episodes_dir: @episodes_dir
    )

    assert_equal "First", title["test_pod-2026-03-01.mp3"]
    assert_equal "Second", title["test_pod-2026-03-01a.mp3"]
  end

  def test_build_correct_after_middle_entry_scrapped
    # Entry "b" was scrapped from history, but "c" file still exists on disk
    history = [
      { "date" => "2026-03-01", "title" => "First", "basename" => "test_pod-2026-03-01" },
      { "date" => "2026-03-01", "title" => "Third", "basename" => "test_pod-2026-03-01b" }
    ]
    path = write_history(history)

    title, _, _ = HistoryMaps.build(
      history_path: path, podcast_name: "test_pod", episodes_dir: @episodes_dir
    )

    assert_equal "First", title["test_pod-2026-03-01.mp3"]
    # Must use basename "b", not positional index "a"
    assert_equal "Third", title["test_pod-2026-03-01b.mp3"]
    refute title.key?("test_pod-2026-03-01a.mp3")
  end

  def test_build_falls_back_to_positional_without_basename
    # Old-format entries without basename field
    history = [
      { "date" => "2026-03-01", "title" => "First" },
      { "date" => "2026-03-01", "title" => "Second" }
    ]
    path = write_history(history)

    title, _, _ = HistoryMaps.build(
      history_path: path, podcast_name: "test_pod", episodes_dir: @episodes_dir
    )

    assert_equal "First", title["test_pod-2026-03-01.mp3"]
    assert_equal "Second", title["test_pod-2026-03-01a.mp3"]
  end

  def test_build_basename_with_languages
    history = [
      { "date" => "2026-03-01", "title" => "Episode", "basename" => "test_pod-2026-03-01b", "duration" => 300 }
    ]
    path = write_history(history)

    title, _, duration = HistoryMaps.build(
      history_path: path, podcast_name: "test_pod",
      episodes_dir: @episodes_dir, languages: ["es"]
    )

    assert_equal "Episode", title["test_pod-2026-03-01b.mp3"]
    assert_equal "Episode", title["test_pod-2026-03-01b-es.mp3"]
    assert_equal 300, duration["test_pod-2026-03-01b-es.mp3"]
  end

  # --- Optional fields ---

  def test_missing_optional_fields_omitted
    history = [{ "date" => "2026-03-01" }]
    path = write_history(history)

    title, timestamp, duration = HistoryMaps.build(
      history_path: path,
      podcast_name: "test_pod",
      episodes_dir: @episodes_dir
    )

    assert_empty title
    assert_empty timestamp
    assert_empty duration
  end

  private

  def write_history(entries)
    path = File.join(@tmpdir, "history.yml")
    File.write(path, entries.to_yaml)
    path
  end
end
