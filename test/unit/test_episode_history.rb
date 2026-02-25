# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "episode_history"

class TestEpisodeHistory < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_history_test")
    @history_path = File.join(@tmpdir, "history.yml")
    @history = EpisodeHistory.new(@history_path)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_record_appends_entry
    @history.record!(date: Date.today, title: "Ep 1", topics: ["AI"], urls: ["https://example.com"])

    entries = YAML.load_file(@history_path)
    assert_equal 1, entries.length
    assert_equal "Ep 1", entries[0]["title"]
    assert_equal ["AI"], entries[0]["topics"]
  end

  def test_record_multiple_entries
    @history.record!(date: Date.today, title: "Ep 1", topics: ["AI"], urls: [])
    @history.record!(date: Date.today, title: "Ep 2", topics: ["Ruby"], urls: [])

    entries = YAML.load_file(@history_path)
    assert_equal 2, entries.length
  end

  def test_recent_episodes_filters_by_lookback
    old_date = Date.today - 10  # older than 7-day lookback
    recent_date = Date.today - 1

    @history.record!(date: old_date, title: "Old", topics: ["old"], urls: [])
    @history.record!(date: recent_date, title: "Recent", topics: ["new"], urls: [])

    # re-read fresh to avoid prune side-effect — record! prunes on write
    history = EpisodeHistory.new(@history_path)
    recent = history.recent_episodes
    # The old entry was pruned on the second record! call
    assert_equal 1, recent.length
    assert_equal "Recent", recent[0]["title"]
  end

  def test_recent_urls_returns_set
    @history.record!(
      date: Date.today,
      title: "Ep 1",
      topics: ["AI"],
      urls: ["https://a.com", "https://b.com"]
    )
    @history.record!(
      date: Date.today,
      title: "Ep 2",
      topics: ["Ruby"],
      urls: ["https://b.com", "https://c.com"]
    )

    urls = @history.recent_urls
    assert_kind_of Set, urls
    assert_includes urls, "https://a.com"
    assert_includes urls, "https://b.com"
    assert_includes urls, "https://c.com"
  end

  def test_recent_topics_summary_format
    @history.record!(date: Date.today, title: "Ep 1", topics: ["AI", "Ruby"], urls: [])

    summary = @history.recent_topics_summary
    refute_nil summary
    assert_includes summary, "AI; Ruby"
    assert_includes summary, Date.today.to_s
  end

  def test_recent_topics_summary_nil_when_empty
    history = EpisodeHistory.new(@history_path)
    assert_nil history.recent_topics_summary
  end

  def test_remove_last_pops_entry
    @history.record!(date: Date.today, title: "Ep 1", topics: ["AI"], urls: [])
    @history.record!(date: Date.today, title: "Ep 2", topics: ["Ruby"], urls: [])

    removed = @history.remove_last!
    assert_equal "Ep 2", removed["title"]

    entries = YAML.load_file(@history_path)
    assert_equal 1, entries.length
    assert_equal "Ep 1", entries[0]["title"]
  end

  def test_remove_last_on_empty_returns_nil
    assert_nil @history.remove_last!
  end

  def test_remove_last_on_nonexistent_file_returns_nil
    history = EpisodeHistory.new(File.join(@tmpdir, "nonexistent.yml"))
    assert_nil history.remove_last!
  end

  def test_record_prunes_old_entries
    old_date = Date.today - 10
    @history.record!(date: old_date, title: "Old", topics: ["old"], urls: [])
    @history.record!(date: Date.today, title: "New", topics: ["new"], urls: [])

    entries = YAML.load_file(@history_path)
    # Old entry should have been pruned
    assert_equal 1, entries.length
    assert_equal "New", entries[0]["title"]
  end
end
