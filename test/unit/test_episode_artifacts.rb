# frozen_string_literal: true

require_relative "../test_helper"
require "episode_artifacts"

class TestEpisodeArtifacts < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("episode_artifacts")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def touch(name)
    File.write(File.join(@dir, name), "x")
  end

  # ── three glob patterns ────────────────────────────────────────────

  def test_finds_dot_extension_artifacts
    %w[pod-2026-05-16.mp3 pod-2026-05-16.mp4 pod-2026-05-16.srt].each { |f| touch(f) }
    paths = EpisodeArtifacts.for_basename(@dir, "pod-2026-05-16")
    assert_equal 3, paths.length
    assert(paths.all? { |p| File.basename(p).start_with?("pod-2026-05-16.") })
  end

  def test_finds_underscore_artifacts
    %w[pod-2026-05-16_script.md pod-2026-05-16_transcript.md pod-2026-05-16_transcript.html
       pod-2026-05-16_timestamps.json pod-2026-05-16_cover.jpg pod-2026-05-16_cover1.png].each { |f| touch(f) }
    paths = EpisodeArtifacts.for_basename(@dir, "pod-2026-05-16")
    assert_equal 6, paths.length
  end

  def test_finds_language_variants
    %w[pod-2026-05-16-jp.mp3 pod-2026-05-16-jp_script.md pod-2026-05-16-it.mp3].each { |f| touch(f) }
    paths = EpisodeArtifacts.for_basename(@dir, "pod-2026-05-16")
    assert_equal 3, paths.length
  end

  # ── strict basename scoping ────────────────────────────────────────

  def test_does_not_match_sibling_suffixed_basenames
    touch("pod-2026-05-16.mp3")
    touch("pod-2026-05-16a.mp3")
    touch("pod-2026-05-16d.mp3")
    paths = EpisodeArtifacts.for_basename(@dir, "pod-2026-05-16")
    assert_equal 1, paths.length
    assert_match(/pod-2026-05-16\.mp3\z/, paths.first)
  end

  def test_does_not_match_sibling_script_md_files
    touch("pod-2026-05-16_script.md")
    touch("pod-2026-05-16a_script.md")
    paths = EpisodeArtifacts.for_basename(@dir, "pod-2026-05-16")
    assert_equal 1, paths.length
  end

  # ── _concat exclusion ──────────────────────────────────────────────

  def test_excludes_concat_files
    touch("pod-2026-05-16.mp3")
    touch("pod-2026-05-16_concat.mp3")
    touch("pod-2026-05-16_concat.txt")
    paths = EpisodeArtifacts.for_basename(@dir, "pod-2026-05-16")
    assert_equal 1, paths.length
    refute(paths.any? { |p| p.include?("_concat") })
  end

  # ── tidiness ───────────────────────────────────────────────────────

  def test_returns_sorted_unique
    %w[pod-2026-05-16.mp3 pod-2026-05-16_script.md pod-2026-05-16.mp4].each { |f| touch(f) }
    paths = EpisodeArtifacts.for_basename(@dir, "pod-2026-05-16")
    assert_equal paths.sort, paths
    assert_equal paths.uniq, paths
  end

  def test_returns_empty_when_no_match
    touch("other-2026-05-16.mp3")
    assert_empty EpisodeArtifacts.for_basename(@dir, "pod-2026-05-16")
  end
end
