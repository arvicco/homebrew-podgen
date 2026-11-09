# frozen_string_literal: true

require_relative "../test_helper"
require "sources/base_source"

class ConcreteSource < BaseSource
  def initialize(results: {}, logger: nil, available: true)
    super(logger: logger)
    @results = results
    @is_available = available
  end

  private

  def available?
    @is_available
  end

  def search_topic(topic, _exclude_urls)
    @results[topic] || []
  end
end

class FailingSource < BaseSource
  def initialize(error_class: RuntimeError, max_failures: 999, logger: nil)
    super(logger: logger)
    @error_class = error_class
    @max_failures = max_failures
    @call_count = 0
  end

  attr_reader :call_count

  private

  def search_topic(_topic, _exclude_urls)
    @call_count += 1
    raise @error_class, "search failed" if @call_count <= @max_failures
    [{ title: "ok", url: "u", summary: "s" }]
  end
end

class TestBaseSource < Minitest::Test
  # --- research template ---

  def test_research_iterates_topics
    source = ConcreteSource.new(results: {
      "AI" => [{ title: "A", url: "u1", summary: "s" }],
      "Ruby" => [{ title: "R", url: "u2", summary: "s" }]
    })

    results = source.research(["AI", "Ruby"])
    assert_equal 2, results.length
    assert_equal "AI", results[0][:topic]
    assert_equal "Ruby", results[1][:topic]
    assert_equal 1, results[0][:findings].length
    assert_equal 1, results[1][:findings].length
  end

  def test_research_returns_empty_when_unavailable
    source = ConcreteSource.new(available: false)

    results = source.research(["AI", "Ruby"])
    assert_equal 2, results.length
    assert_equal [], results[0][:findings]
    assert_equal [], results[1][:findings]
  end

  def test_research_passes_exclude_urls
    source = ConcreteSource.new
    # ConcreteSource doesn't use exclude_urls, just verify it's accepted
    results = source.research(["AI"], exclude_urls: Set.new(["http://excluded"]))
    assert_equal 1, results.length
  end

  def test_research_handles_empty_topics
    source = ConcreteSource.new
    assert_equal [], source.research([])
  end

  # --- source_name ---

  def test_source_name_defaults_to_class_name
    source = ConcreteSource.new
    assert_equal "ConcreteSource", source.send(:source_name)
  end

  # --- search_topic not implemented ---

  def test_base_raises_not_implemented
    source = BaseSource.new
    assert_raises(NotImplementedError) do
      source.send(:search_topic, "AI", Set.new)
    end
  end

  # --- includes Loggable and Retryable ---

  def test_includes_loggable
    assert BaseSource.ancestors.include?(Loggable)
  end

  def test_includes_retryable
    assert BaseSource.ancestors.include?(Retryable)
  end

  def test_with_retries_available_to_subclasses
    source = ConcreteSource.new
    assert source.respond_to?(:with_retries, true)
  end

  # --- get_json (Q-130): only 429/5xx and network timeouts are retried ---

  FakeResponse = Struct.new(:code, :parsed_response) do
    def success? = (200..299).cover?(code)
  end

  def test_get_json_401_one_request_runtime_error
    source = ConcreteSource.new
    source.define_singleton_method(:sleep) { |_| }
    calls = 0
    HTTParty.stub(:get, ->(*_a, **_k) { (calls += 1) && FakeResponse.new(401, nil) }) do
      err = assert_raises(RuntimeError) { source.send(:get_json, "https://example.com/api", query: { q: "x" }) }
      assert_equal "HTTP 401 from ConcreteSource", err.message
    end
    assert_equal 1, calls
  end

  def test_get_json_503_retried_then_succeeds
    source = ConcreteSource.new
    source.define_singleton_method(:sleep) { |_| }
    responses = [FakeResponse.new(503, nil), FakeResponse.new(200, { "hits" => [] })]
    sent = []
    get = lambda do |url, **kw|
      sent << [url, kw]
      responses.shift
    end
    HTTParty.stub(:get, get) do
      body = source.send(:get_json, "https://example.com/api", query: { q: "x" }, headers: { "A" => "b" })
      assert_equal({ "hits" => [] }, body)
    end
    assert_equal 2, sent.length
    assert_equal ["https://example.com/api", { query: { q: "x" }, headers: { "A" => "b" }, timeout: 15 }], sent.first
  end

  def test_get_json_connection_reset_retried_then_succeeds
    source = ConcreteSource.new
    source.define_singleton_method(:sleep) { |_| }
    calls = 0
    get = lambda do |*_a, **_k|
      calls += 1
      raise Errno::ECONNRESET if calls == 1
      FakeResponse.new(200, { "ok" => true })
    end
    HTTParty.stub(:get, get) do
      assert_equal({ "ok" => true }, source.send(:get_json, "https://example.com/api", query: {}))
    end
    assert_equal 2, calls
  end

  # --- post_json (P16-4): the POST sibling with the same transient retries ---

  def test_post_json_503_retried_then_succeeds
    source = ConcreteSource.new
    source.define_singleton_method(:sleep) { |_| }
    responses = [FakeResponse.new(503, nil), FakeResponse.new(200, { "ok" => true })]
    sent = []
    post = lambda do |url, **kw|
      sent << [url, kw]
      responses.shift
    end
    HTTParty.stub(:post, post) do
      body = source.send(:post_json, "https://example.com/api", body: "{}", headers: { "A" => "b" })
      assert_equal({ "ok" => true }, body)
    end
    assert_equal 2, sent.length
    assert_equal ["https://example.com/api", { body: "{}", headers: { "A" => "b" }, timeout: 15 }], sent.first
  end

  def test_post_json_401_one_request_runtime_error
    source = ConcreteSource.new
    source.define_singleton_method(:sleep) { |_| }
    calls = 0
    HTTParty.stub(:post, ->(*_a, **_k) { (calls += 1) && FakeResponse.new(401, nil) }) do
      err = assert_raises(RuntimeError) { source.send(:post_json, "https://example.com/api", body: "{}") }
      assert_equal "HTTP 401 from ConcreteSource", err.message
    end
    assert_equal 1, calls
  end

  # --- empty_results ---

  def test_empty_results_preserves_topics
    source = ConcreteSource.new(available: false)
    results = source.research(["AI", "Ruby", "Go"])
    assert_equal %w[AI Ruby Go], results.map { |r| r[:topic] }
  end
end
