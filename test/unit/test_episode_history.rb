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

    history = EpisodeHistory.new(@history_path)
    recent = history.recent_episodes
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

  def test_remove_by_date_removes_specific_entry
    @history.record!(date: "2026-03-01", title: "Ep 1", topics: ["a"], urls: [])
    @history.record!(date: "2026-03-02", title: "Ep 2", topics: ["b"], urls: [])
    @history.record!(date: "2026-03-03", title: "Ep 3", topics: ["c"], urls: [])

    removed = @history.remove_by_date!("2026-03-02", 0)
    assert_equal "Ep 2", removed["title"]

    entries = YAML.load_file(@history_path)
    assert_equal 2, entries.length
    assert_equal "Ep 1", entries[0]["title"]
    assert_equal "Ep 3", entries[1]["title"]
  end

  def test_remove_by_date_with_suffix_index_removes_correct_entry
    @history.record!(date: "2026-03-01", title: "Ep 1a", topics: ["a"], urls: [])
    @history.record!(date: "2026-03-01", title: "Ep 1b", topics: ["b"], urls: [])
    @history.record!(date: "2026-03-01", title: "Ep 1c", topics: ["c"], urls: [])

    # suffix_index 1 = second entry for that date (the "a" suffix)
    removed = @history.remove_by_date!("2026-03-01", 1)
    assert_equal "Ep 1b", removed["title"]

    entries = YAML.load_file(@history_path)
    assert_equal 2, entries.length
    assert_equal "Ep 1a", entries[0]["title"]
    assert_equal "Ep 1c", entries[1]["title"]
  end

  def test_remove_by_date_returns_nil_for_missing_date
    @history.record!(date: "2026-03-01", title: "Ep 1", topics: ["a"], urls: [])
    assert_nil @history.remove_by_date!("2026-03-15", 0)
  end

  def test_remove_by_date_returns_nil_for_out_of_range_suffix
    @history.record!(date: "2026-03-01", title: "Ep 1", topics: ["a"], urls: [])
    assert_nil @history.remove_by_date!("2026-03-01", 5)
  end

  def test_record_preserves_all_entries
    old_date = Date.today - 10
    @history.record!(date: old_date, title: "Old", topics: ["old"], urls: ["https://old.com"])
    @history.record!(date: Date.today, title: "New", topics: ["new"], urls: ["https://new.com"])

    entries = YAML.load_file(@history_path)
    assert_equal 2, entries.length
    assert_equal "Old", entries[0]["title"]
    assert_equal "New", entries[1]["title"]
  end

  def test_all_urls_returns_all_entries
    old_date = Date.today - 10
    @history.record!(date: old_date, title: "Old", topics: ["old"], urls: ["https://old.com"])
    @history.record!(date: Date.today, title: "New", topics: ["new"], urls: ["https://new.com"])

    urls = @history.all_urls
    assert_kind_of Set, urls
    assert_includes urls, "https://old.com"
    assert_includes urls, "https://new.com"
  end

  def test_recent_urls_excludes_old_entries
    old_date = Date.today - 10
    @history.record!(date: old_date, title: "Old", topics: ["old"], urls: ["https://old.com"])
    @history.record!(date: Date.today, title: "New", topics: ["new"], urls: ["https://new.com"])

    urls = @history.recent_urls
    refute_includes urls, "https://old.com"
    assert_includes urls, "https://new.com"
  end

  def test_record_stores_duration_and_timestamp
    ts = "2026-03-02T10:30:00+00:00"
    @history.record!(date: Date.today, title: "Ep 1", topics: ["AI"], urls: [],
                     duration: 123.45, timestamp: ts)

    entries = YAML.load_file(@history_path)
    assert_equal 1, entries.length
    assert_equal 123.45, entries[0]["duration"]
    assert_equal ts, entries[0]["timestamp"]
  end

  # --- basename support ---

  def test_record_stores_basename
    @history.record!(date: Date.today, title: "Ep 1", topics: ["AI"], urls: [],
                     basename: "mypod-2026-03-01a")

    entries = YAML.load_file(@history_path)
    assert_equal "mypod-2026-03-01a", entries[0]["basename"]
  end

  # --- excluded URLs merging ---

  def test_all_urls_includes_excluded_urls
    @history.record!(date: Date.today, title: "Ep", topics: [], urls: ["https://a.com"])
    excluded_path = File.join(@tmpdir, "excluded_urls.yml")
    File.write(excluded_path, ["https://b.com"].to_yaml)

    history = EpisodeHistory.new(@history_path, excluded_urls_path: excluded_path)
    urls = history.all_urls

    assert_includes urls, "https://a.com"
    assert_includes urls, "https://b.com"
  end

  def test_recent_urls_includes_excluded_urls
    @history.record!(date: Date.today, title: "Ep", topics: [], urls: ["https://a.com"])
    excluded_path = File.join(@tmpdir, "excluded_urls.yml")
    File.write(excluded_path, ["https://b.com"].to_yaml)

    history = EpisodeHistory.new(@history_path, excluded_urls_path: excluded_path)
    urls = history.recent_urls

    assert_includes urls, "https://a.com"
    assert_includes urls, "https://b.com"
  end

  def test_all_urls_works_without_excluded_path
    @history.record!(date: Date.today, title: "Ep", topics: [], urls: ["https://a.com"])

    urls = @history.all_urls
    assert_includes urls, "https://a.com"
  end

  def test_record_omits_nil_basename
    @history.record!(date: Date.today, title: "Ep 1", topics: ["AI"], urls: [])

    entries = YAML.load_file(@history_path)
    refute entries[0].key?("basename")
  end

  def test_remove_by_basename_finds_and_removes
    @history.record!(date: "2026-03-01", title: "Ep A", topics: [], urls: [], basename: "pod-2026-03-01")
    @history.record!(date: "2026-03-01", title: "Ep B", topics: [], urls: [], basename: "pod-2026-03-01a")
    @history.record!(date: "2026-03-01", title: "Ep C", topics: [], urls: [], basename: "pod-2026-03-01b")

    removed = @history.remove_by_basename!("pod-2026-03-01a")
    assert_equal "Ep B", removed["title"]

    entries = YAML.load_file(@history_path)
    assert_equal 2, entries.length
    assert_equal "Ep A", entries[0]["title"]
    assert_equal "Ep C", entries[1]["title"]
  end

  def test_remove_by_basename_returns_nil_when_not_found
    @history.record!(date: "2026-03-01", title: "Ep A", topics: [], urls: [], basename: "pod-2026-03-01")

    assert_nil @history.remove_by_basename!("pod-2026-03-99")
  end

  def test_record_omits_nil_duration_and_timestamp
    @history.record!(date: Date.today, title: "Ep 1", topics: ["AI"], urls: [])

    entries = YAML.load_file(@history_path)
    assert_equal 1, entries.length
    refute entries[0].key?("duration")
    refute entries[0].key?("timestamp")
  end
end
