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

  # --- empty_results ---

  def test_empty_results_preserves_topics
    source = ConcreteSource.new(available: false)
    results = source.research(["AI", "Ruby", "Go"])
    assert_equal %w[AI Ruby Go], results.map { |r| r[:topic] }
  end
end
