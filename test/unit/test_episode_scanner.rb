# frozen_string_literal: true

require_relative "../test_helper"
require "episode_scanner"

class TestEpisodeScanner < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("episode_scanner")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def touch(name, content = "x")
    File.write(File.join(@dir, name), content)
  end

  # ── no filter: returns all .mp3 with adjacent text file ────────────

  def test_scan_returns_all_episodes_with_transcripts
    %w[pod-2026-05-14 pod-2026-05-16].each do |b|
      touch("#{b}.mp3")
      touch("#{b}_transcript.md")
    end
    result = EpisodeScanner.scan(@dir)
    assert_equal 2, result.length
    assert_equal %w[pod-2026-05-14 pod-2026-05-16], result.map { |e| e[:base_name] }
  end

  def test_scan_excludes_episodes_without_text_file
    touch("pod-2026-05-16.mp3")
    # no transcript or script for this one
    touch("pod-2026-05-17.mp3")
    touch("pod-2026-05-17_transcript.md")
    result = EpisodeScanner.scan(@dir)
    assert_equal 1, result.length
    assert_equal "pod-2026-05-17", result.first[:base_name]
  end

  def test_scan_uses_script_md_when_transcript_missing
    # News-pipeline episodes have _script.md but not _transcript.md.
    touch("pod-2026-05-16.mp3")
    touch("pod-2026-05-16_script.md")
    result = EpisodeScanner.scan(@dir)
    assert_equal 1, result.length
    assert_match(/_script\.md\z/, result.first[:transcript_path])
  end

  def test_scan_prefers_transcript_over_script
    touch("pod-2026-05-16.mp3")
    touch("pod-2026-05-16_script.md")
    touch("pod-2026-05-16_transcript.md")
    result = EpisodeScanner.scan(@dir)
    assert_match(/_transcript\.md\z/, result.first[:transcript_path])
  end

  def test_scan_returns_empty_when_dir_missing
    assert_empty EpisodeScanner.scan("/nonexistent/path")
  end

  def test_scan_returns_sorted_by_basename
    %w[pod-2026-05-18 pod-2026-05-14 pod-2026-05-16].each do |b|
      touch("#{b}.mp3")
      touch("#{b}_transcript.md")
    end
    assert_equal %w[pod-2026-05-14 pod-2026-05-16 pod-2026-05-18],
      EpisodeScanner.scan(@dir).map { |e| e[:base_name] }
  end

  # ── episode_id filter ──────────────────────────────────────────────

  def test_scan_with_episode_id_filters_to_exact_basename_suffix
    # Same scrap-style strict interpretation publish has always used:
    # `--date 2026-05-16` means the bare-suffix episode for that day.
    # To target the d-suffix variant, user types `--date 2026-05-16d`.
    %w[pod-2026-05-14 pod-2026-05-16 pod-2026-05-16d].each do |b|
      touch("#{b}.mp3")
      touch("#{b}_transcript.md")
    end
    result = EpisodeScanner.scan(@dir, episode_id: "2026-05-16")
    assert_equal 1, result.length
    assert_equal "pod-2026-05-16", result.first[:base_name]
  end

  def test_scan_with_full_suffix_id_narrows_to_exact_match
    %w[pod-2026-05-16 pod-2026-05-16a pod-2026-05-16d].each do |b|
      touch("#{b}.mp3")
      touch("#{b}_transcript.md")
    end
    result = EpisodeScanner.scan(@dir, episode_id: "2026-05-16d")
    assert_equal 1, result.length
    assert_equal "pod-2026-05-16d", result.first[:base_name]
  end

  def test_scan_returns_empty_when_episode_id_does_not_match
    touch("pod-2026-05-16.mp3")
    touch("pod-2026-05-16_transcript.md")
    assert_empty EpisodeScanner.scan(@dir, episode_id: "2099-01-01")
  end

  def test_scan_with_nil_episode_id_same_as_omitted
    touch("pod-2026-05-16.mp3")
    touch("pod-2026-05-16_transcript.md")
    assert_equal EpisodeScanner.scan(@dir), EpisodeScanner.scan(@dir, episode_id: nil)
  end
end
