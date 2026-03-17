# frozen_string_literal: true

require_relative "../test_helper"
require "priority_links"

class TestPriorityLinks < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_priority_links_test")
    @path = File.join(@tmpdir, "links.yml")
    @links = PriorityLinks.new(@path)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- all ---

  def test_all_returns_empty_when_no_file
    assert_equal [], @links.all
  end

  def test_all_returns_entries_from_file
    File.write(@path, [{ "url" => "https://example.com", "added" => "2026-03-18" }].to_yaml)
    entries = @links.all
    assert_equal 1, entries.length
    assert_equal "https://example.com", entries.first["url"]
  end

  def test_all_returns_empty_for_corrupt_file
    File.write(@path, "not valid yaml: [[[")
    assert_equal [], @links.all
  end

  def test_all_returns_empty_for_non_array_yaml
    File.write(@path, { "key" => "value" }.to_yaml)
    assert_equal [], @links.all
  end

  # --- empty? / count ---

  def test_empty_when_no_links
    assert @links.empty?
    assert_equal 0, @links.count
  end

  def test_not_empty_after_add
    @links.add("https://example.com")
    refute @links.empty?
    assert_equal 1, @links.count
  end

  # --- add ---

  def test_add_creates_file_and_stores_link
    result = @links.add("https://example.com")
    assert result, "add should return true for new URL"
    assert File.exist?(@path)

    entries = YAML.load_file(@path)
    assert_equal 1, entries.length
    assert_equal "https://example.com", entries.first["url"]
    assert_equal Date.today.to_s, entries.first["added"]
  end

  def test_add_with_note
    @links.add("https://example.com", note: "Great article")

    entries = YAML.load_file(@path)
    assert_equal "Great article", entries.first["note"]
  end

  def test_add_without_note_omits_key
    @links.add("https://example.com")

    entries = YAML.load_file(@path)
    refute entries.first.key?("note")
  end

  def test_add_empty_note_omits_key
    @links.add("https://example.com", note: "")

    entries = YAML.load_file(@path)
    refute entries.first.key?("note")
  end

  def test_add_deduplicates_by_url
    @links.add("https://example.com")
    result = @links.add("https://example.com")

    refute result, "add should return false for duplicate URL"
    assert_equal 1, @links.count
  end

  def test_add_multiple_urls
    @links.add("https://example.com/1")
    @links.add("https://example.com/2")
    @links.add("https://example.com/3")

    assert_equal 3, @links.count
  end

  # --- remove ---

  def test_remove_existing_url
    @links.add("https://example.com/1")
    @links.add("https://example.com/2")

    result = @links.remove("https://example.com/1")

    assert result, "remove should return true when URL was found"
    assert_equal 1, @links.count
    assert_equal "https://example.com/2", @links.all.first["url"]
  end

  def test_remove_nonexistent_url
    @links.add("https://example.com/1")

    result = @links.remove("https://example.com/999")

    refute result, "remove should return false when URL not found"
    assert_equal 1, @links.count
  end

  def test_remove_last_link_cleans_up
    @links.add("https://example.com")
    @links.remove("https://example.com")

    assert @links.empty?
  end

  # --- clear! ---

  def test_clear_removes_all_links
    @links.add("https://example.com/1")
    @links.add("https://example.com/2")

    count = @links.clear!

    assert_equal 2, count
    assert @links.empty?
    refute File.exist?(@path)
  end

  def test_clear_empty_returns_zero
    count = @links.clear!
    assert_equal 0, count
  end

  # --- consume! ---

  def test_consume_removes_specified_urls
    @links.add("https://example.com/1")
    @links.add("https://example.com/2")
    @links.add("https://example.com/3")

    @links.consume!(["https://example.com/1", "https://example.com/3"])

    assert_equal 1, @links.count
    assert_equal "https://example.com/2", @links.all.first["url"]
  end

  def test_consume_all_links_cleans_up
    @links.add("https://example.com/1")
    @links.consume!(["https://example.com/1"])

    assert @links.empty?
  end

  def test_consume_nonexistent_urls_is_safe
    @links.add("https://example.com/1")
    @links.consume!(["https://example.com/999"])

    assert_equal 1, @links.count
  end

  # --- fetch_all ---

  def test_fetch_all_returns_empty_when_no_links
    assert_equal [], @links.fetch_all
  end

  def test_fetch_all_returns_findings_with_fallback_title
    @links.add("https://httpbin.org/status/404")

    findings = @links.fetch_all
    assert_equal 1, findings.length
    finding = findings.first
    assert_equal "https://httpbin.org/status/404", finding[:url]
    # Title falls back to URL when page can't be fetched
    assert_kind_of String, finding[:title]
    assert_kind_of String, finding[:summary]
  end

  def test_fetch_all_includes_note_in_summary
    File.write(@path, [{ "url" => "https://httpbin.org/status/404", "added" => "2026-03-18", "note" => "Important article" }].to_yaml)

    findings = @links.fetch_all
    assert_includes findings.first[:summary], "Important article"
  end

  # --- atomic writes ---

  def test_concurrent_add_does_not_corrupt
    # Write initial state
    @links.add("https://example.com/initial")

    # Simulate concurrent adds via separate instances
    links2 = PriorityLinks.new(@path)
    links2.add("https://example.com/second")

    entries = YAML.load_file(@path)
    assert_equal 2, entries.length
  end

  # --- persistence ---

  def test_data_persists_across_instances
    @links.add("https://example.com/persist")

    new_instance = PriorityLinks.new(@path)
    assert_equal 1, new_instance.count
    assert_equal "https://example.com/persist", new_instance.all.first["url"]
  end
end
