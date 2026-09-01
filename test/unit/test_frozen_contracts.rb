# frozen_string_literal: true

require_relative "../test_helper"
require "tmpdir"
require "fileutils"
require "yaml"
require "json"
require "rexml/document"
require "episode_history"
require "upload_tracker"
require "timestamp_persister"
require "rss_generator"
require "history_maps"

# M0-5 — pinning tests for the FROZEN DOMAIN (CLAUDE.md golden rules
# 4–5): the machine-readable shapes subscribers and downstream tooling
# depend on. These tests assert EXACT shapes on purpose: any change —
# even an additive one — must consciously update the matching
# assertion in the SAME commit. If one of these fails, you are
# touching a frozen contract; stop and check the rules before
# "fixing" the test.
class TestFrozenContracts < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_contract_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- history.yml schema (owner data; consumed by HistoryMaps → RSS/site) ---

  def test_history_entry_key_set_is_frozen
    history = EpisodeHistory.new(File.join(@tmpdir, "history.yml"))
    history.record!(
      date: "2026-01-15", title: "T", topics: ["a"], urls: ["https://x/y.mp3"],
      duration: 123.4, timestamp: "2026-01-15T06:00:00+01:00",
      basename: "pod-2026-01-15", languages: {sl: {"duration" => 120.0}}
    )
    history.record_language!(
      basename: "pod-2026-01-15", language_code: "it",
      duration: 118.2, voiced_at: "2026-01-16T06:00:00+01:00"
    )

    raw = YAML.safe_load_file(File.join(@tmpdir, "history.yml"))
    assert_equal 1, raw.length
    entry = raw.first
    assert_equal %w[date title topics urls duration timestamp basename languages],
      entry.keys, "history.yml entry key set/order is a frozen contract"
    assert_equal "2026-01-15", entry["date"], "date is a plain ISO string"
    assert_kind_of Array, entry["topics"]
    assert_kind_of Array, entry["urls"]
    assert_equal %w[sl it], entry["languages"].keys, "language keys are strings"
    assert_equal %w[duration voiced_at], entry["languages"]["it"].keys
  end

  # --- uploads.yml schema (platform → group → { basename → id }) ---

  def test_uploads_tracker_nesting_shape_is_frozen
    path = File.join(@tmpdir, "uploads.yml")
    tracker = UploadTracker.new(path)
    tracker.record("lingq", "some-collection", "pod-2026-01-15", 4711)
    tracker.record("youtube", "PLxyz", "pod-2026-01-15", "vid123")

    raw = YAML.safe_load_file(path)
    assert_equal({"lingq" => {"some-collection" => {"pod-2026-01-15" => 4711}},
                  "youtube" => {"PLxyz" => {"pod-2026-01-15" => "vid123"}}},
      raw, "uploads.yml is exactly platform → group → { basename → id }")
  end

  # --- *_timestamps.json schema ---

  def test_timestamps_sidecar_schema_is_frozen
    path = File.join(@tmpdir, "ep_timestamps.json")
    TimestampPersister.persist(
      segments: [{start: 0.0, end: 4.2, text: "hello"}],
      engine: "groq", intro_duration: 3.5, output_path: path
    )

    raw = JSON.parse(File.read(path))
    assert_equal %w[version engine intro_duration segments], raw.keys
    assert_equal 1, raw["version"], "schema version bump is a frozen-domain change"
    assert_equal %w[start end text], raw["segments"].first.keys
    assert_equal 3.5, raw["segments"].first["start"], "segment times carry the intro offset"

    TimestampPersister.update_segments(path, raw["segments"])
    raw2 = JSON.parse(File.read(path))
    assert_equal %w[version engine intro_duration segments reconciled], raw2.keys,
      "reconciled flag is the only additive key update_segments may add"
    assert_equal true, raw2["reconciled"]
  end

  # --- episode basename scheme + RSS feed item shape ---

  def make_episode(episodes_dir, basename)
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "#{basename}.mp3"), "x" * 1000)
  end

  def test_history_maps_basename_derivation_is_frozen
    # Same-day episodes suffix "", "a"..; explicit basename wins.
    history_path = File.join(@tmpdir, "history.yml")
    File.write(history_path, YAML.dump([
      {"date" => "2026-01-15", "title" => "One", "topics" => []},
      {"date" => "2026-01-15", "title" => "Two", "topics" => []},
      {"date" => "2026-01-16", "title" => "Named", "topics" => [], "basename" => "pod-2026-01-16b"}
    ]))
    title_map, = HistoryMaps.build(
      history_path: history_path, podcast_name: "pod",
      episodes_dir: File.join(@tmpdir, "episodes"), languages: []
    )
    assert_equal ["pod-2026-01-15.mp3", "pod-2026-01-15a.mp3", "pod-2026-01-16b.mp3"],
      title_map.keys, "basename scheme <podcast>-<date><''|a..z> is frozen"
  end

  def test_rss_feed_item_shape_is_frozen
    episodes_dir = File.join(@tmpdir, "episodes")
    make_episode(episodes_dir, "pod-2026-01-15")
    history_path = File.join(@tmpdir, "history.yml")
    File.write(history_path, YAML.dump([
      {"date" => "2026-01-15", "title" => "Ep Title", "topics" => [],
       "duration" => 83.0, "basename" => "pod-2026-01-15",
       "timestamp" => "2026-01-15T07:30:05+01:00"}
    ]))

    feed_path = File.join(@tmpdir, "feed.xml")
    # Primary feed semantics: language "en" == suffix-less basenames
    # (translated feeds select the -xx suffixed episodes instead).
    RssGenerator.new(
      episodes_dir: episodes_dir, feed_path: feed_path,
      title: "Pod", description: "D", author: "A", language: "en",
      base_url: "https://cdn.example/pod", history_path: history_path
    ).generate

    doc = REXML::Document.new(File.read(feed_path))
    channel = doc.root.elements["channel"]
    items = channel.get_elements("item")
    assert_equal 1, items.length
    item = items.first

    assert_equal %w[title pubDate itunes:author itunes:duration enclosure guid],
      item.elements.map(&:expanded_name),
      "RSS item element set/order is a frozen contract (podcast:transcript only when HTML exists)"

    assert_equal "Ep Title", item.elements["title"].text
    assert_equal "1:23", item.elements["itunes:duration"].text, "duration renders m:ss from history"

    enclosure = item.elements["enclosure"]
    assert_equal "https://cdn.example/pod/episodes/pod-2026-01-15.mp3", enclosure.attributes["url"]
    assert_equal "1000", enclosure.attributes["length"], "enclosure length is the live file size"
    assert_equal "audio/mpeg", enclosure.attributes["type"]

    assert_equal "pod-2026-01-15.mp3", item.elements["guid"].text,
      "guid IS the bare mp3 filename — changing this re-downloads every episode for every subscriber"

    assert_match(/\AThu, 15 Jan 2026 07:30:05/, item.elements["pubDate"].text,
      "pubDate = episode date + processing time-of-day")

    assert_equal "2.0", doc.root.attributes["version"]
    %w[title description link language generator itunes:author itunes:explicit lastBuildDate].each do |el|
      refute_nil channel.elements[el], "channel element #{el} is part of the frozen shape"
    end
  end
end
