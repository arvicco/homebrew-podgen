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
    @links.add("https://example.com/article")

    # Stub fetch_page_info to simulate a failed fetch
    @links.define_singleton_method(:fetch_page_info) { |_url, **_kw| [nil, nil] }

    findings = @links.fetch_all
    assert_equal 1, findings.length
    finding = findings.first
    assert_equal "https://example.com/article", finding[:url]
    assert_equal "https://example.com/article", finding[:title], "Title should fall back to URL"
    assert_equal "Priority link added by producer", finding[:summary]
  end

  def test_fetch_all_returns_findings_with_page_info
    @links.add("https://example.com/article")

    @links.define_singleton_method(:fetch_page_info) { |_url, **_kw| ["Great Article Title", "A summary of the article."] }

    findings = @links.fetch_all
    finding = findings.first
    assert_equal "Great Article Title", finding[:title]
    assert_equal "A summary of the article.", finding[:summary]
  end

  def test_fetch_all_includes_note_in_summary
    File.write(@path, [{ "url" => "https://example.com/article", "added" => "2026-03-18", "note" => "Important article" }].to_yaml)

    @links.define_singleton_method(:fetch_page_info) { |_url, **_kw| [nil, "Page summary"] }

    findings = @links.fetch_all
    assert_includes findings.first[:summary], "Important article"
    assert_includes findings.first[:summary], "Page summary"
  end

  def test_fetch_all_note_only_when_no_page_info
    File.write(@path, [{ "url" => "https://example.com/article", "added" => "2026-03-18", "note" => "Must cover this" }].to_yaml)

    @links.define_singleton_method(:fetch_page_info) { |_url, **_kw| [nil, nil] }

    findings = @links.fetch_all
    assert_includes findings.first[:summary], "Must cover this"
  end

  # --- fetch seam (P8-4, Q-63) ---

  FakeResponse = Struct.new(:code, :headers, :body) do
    def [](key) = headers[key]
  end

  class RecordingLogger
    attr_reader :lines, :warnings

    def initialize
      @lines = []
      @warnings = []
    end

    def log(msg) = @lines << msg
    def warning(msg) = @warnings << msg
  end

  def test_fetch_page_info_relative_redirect_resolves_and_returns_title
    requested = []
    replies = [
      FakeResponse.new("301", {"location" => "/article"}, ""),
      FakeResponse.new("200", {}, "<html><title>Real Title</title></html>")
    ]
    links = PriorityLinks.new(@path, fetcher: ->(uri) {
      requested << uri.to_s
      replies.shift
    })

    title, = links.send(:fetch_page_info, "https://example.com/short")

    assert_equal "Real Title", title
    assert_equal ["https://example.com/short", "https://example.com/article"], requested
  end

  def test_fetch_all_failed_fetch_warns_with_class_and_is_not_returned
    links = PriorityLinks.new(@path, fetcher: ->(_uri) { raise SocketError, "getaddrinfo" })
    links.add("https://down.example.com/a")
    logger = RecordingLogger.new

    findings = links.fetch_all(logger: logger)

    assert_equal [], findings, "a failed link is not returned, so it is not consumed"
    assert_equal 1, logger.warnings.length
    assert_includes logger.warnings.first, "Warning: https://down.example.com/a (SocketError"
    refute logger.lines.any? { |l| l.include?("✓") }, "no check mark on failure"
    assert_equal ["https://down.example.com/a"], links.all.map { |e| e["url"] }, "link stays queued"
  end

  # CRPR W2(b): a permanent failure (4xx other than 429) is consumed with one
  # warning: returned titled by its URL (as before P8-4), so generate drops
  # it from the queue instead of warning on every run.
  def test_fetch_all_permanent_http_error_warns_once_and_is_returned_by_url
    links = PriorityLinks.new(@path, fetcher: ->(_uri) { FakeResponse.new("404", {}, "") })
    links.add("https://example.com/gone")
    logger = RecordingLogger.new

    findings = links.fetch_all(logger: logger)

    expected = {title: "https://example.com/gone", url: "https://example.com/gone", summary: "Priority link added by producer"}
    assert_equal [expected], findings
    assert_equal 1, logger.warnings.length
    assert_includes logger.warnings.first, "PriorityLinks::PermanentFetchError"
    assert_includes logger.warnings.first, "HTTP 404"
    refute logger.lines.any? { |l| l.include?("\u2713") }
  end

  def test_fetch_all_gone_and_malformed_urls_are_permanent
    links = PriorityLinks.new(@path, fetcher: ->(_uri) { FakeResponse.new("410", {}, "") })
    File.write(@path, [{"url" => "https://example.com/old"}, {"url" => "ftp://example.com/x"},
      {"url" => "http://exa mple.com/bad"}].to_yaml)
    logger = RecordingLogger.new

    findings = links.fetch_all(logger: logger)

    assert_equal ["https://example.com/old", "ftp://example.com/x", "http://exa mple.com/bad"], findings.map { |f| f[:url] }
    assert_equal 3, logger.warnings.length
  end

  def test_fetch_all_transient_http_error_stays_queued
    links = PriorityLinks.new(@path, fetcher: ->(_uri) { FakeResponse.new("502", {}, "") })
    links.add("https://example.com/flaky")
    logger = RecordingLogger.new

    assert_equal [], links.fetch_all(logger: logger)
    assert_includes logger.warnings.first, "PriorityLinks::FetchError: HTTP 502"
  end

  # CRPR W2(a): a Latin-1 page (or one stray byte) still yields its title.
  def test_fetch_page_info_invalid_utf8_body_returns_title
    body = "<title>Caf\xE9 \xFF news</title>".b
    links = PriorityLinks.new(@path, fetcher: ->(_uri) { FakeResponse.new("200", {}, body) })

    title, = links.send(:fetch_page_info, "https://example.com/latin1")

    assert_includes title, "news"
    assert title.valid_encoding?
  end

  def test_fetch_all_success_logs_title_with_timing
    links = PriorityLinks.new(@path, fetcher: ->(_uri) {
      FakeResponse.new("200", {}, "<title>Hello</title>")
    })
    links.add("https://example.com/a")
    logger = RecordingLogger.new

    findings = links.fetch_all(logger: logger)

    assert_equal "Hello", findings.first[:title]
    assert logger.lines.any? { |l| l.match?(/✓ Hello \(\d+(\.\d+)?s\)/) }, logger.lines.inspect
  end

  def test_http_get_retries_timeouts_then_raises_original_class
    attempts = 0
    raiser = ->(*_a, **_k) {
      attempts += 1
      raise Net::OpenTimeout, "execution expired"
    }
    @links.define_singleton_method(:sleep) { |_s| nil }

    Net::HTTP.stub(:start, raiser) do
      assert_raises(Net::OpenTimeout) { @links.send(:http_get, URI("https://example.com/a")) }
    end
    assert_equal 3, attempts # 1 + 2 retries (with_http_retries default)
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
