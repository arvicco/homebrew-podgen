# frozen_string_literal: true

require_relative "../test_helper"
require "set"

ENV["EXA_API_KEY"] ||= "test-key"
require "source_manager"

class TestSourceManager < Minitest::Test
  # --- normalize_result ---

  def test_normalize_result_with_symbol_keys
    manager = build_manager
    result = manager.send(:normalize_result, {
      topic: "AI", findings: [{ title: "T", url: "U", summary: "S" }]
    })

    assert_equal "AI", result[:topic]
    assert_equal "T", result[:findings].first[:title]
  end

  def test_normalize_result_with_string_keys
    manager = build_manager
    result = manager.send(:normalize_result, {
      "topic" => "AI", "findings" => [{ "title" => "T", "url" => "U", "summary" => "S" }]
    })

    assert_equal "AI", result[:topic]
    assert_equal "T", result[:findings].first[:title]
  end

  def test_normalize_result_missing_findings
    manager = build_manager
    result = manager.send(:normalize_result, { topic: "AI" })
    assert_equal [], result[:findings]
  end

  # --- merge_results ---

  def test_merge_results_combines_same_topic
    manager = build_manager
    existing = [{ topic: "AI", findings: [{ title: "A", url: "u1", summary: "s" }] }]
    new_results = [{ topic: "AI", findings: [{ title: "B", url: "u2", summary: "s" }] }]

    merged = manager.send(:merge_results, existing, new_results)
    assert_equal 1, merged.length
    assert_equal 2, merged.first[:findings].length
  end

  def test_merge_results_appends_new_topics
    manager = build_manager
    existing = [{ topic: "AI", findings: [] }]
    new_results = [{ topic: "Ruby", findings: [{ title: "R", url: "u", summary: "s" }] }]

    merged = manager.send(:merge_results, existing, new_results)
    assert_equal 2, merged.length
    assert_equal "Ruby", merged.last[:topic]
  end

  def test_merge_results_deduplicates_by_url
    manager = build_manager
    existing = [{ topic: "AI", findings: [{ title: "A", url: "same", summary: "s" }] }]
    new_results = [{ topic: "AI", findings: [{ title: "B", url: "same", summary: "s" }] }]

    merged = manager.send(:merge_results, existing, new_results)
    assert_equal 1, merged.first[:findings].length
  end

  def test_merge_results_does_not_mutate_existing
    manager = build_manager
    existing = [{ topic: "AI", findings: [{ title: "A", url: "u1", summary: "s" }] }]
    manager.send(:merge_results, existing, [{ topic: "Ruby", findings: [] }])
    assert_equal 1, existing.length
  end

  # --- research with mock sources ---

  def test_research_runs_sources_and_merges
    manager = build_manager
    source1 = MockSource.new([{ topic: "AI", findings: [{ title: "A", url: "u1", summary: "s" }] }])
    source2 = MockSource.new([{ topic: "Ruby", findings: [{ title: "R", url: "u2", summary: "s" }] }])

    manager.define_singleton_method(:enabled_sources) do
      [["src1", source1], ["src2", source2]]
    end

    results = manager.research(["AI", "Ruby"])
    assert_equal 2, results.length
    topics = results.map { |r| r[:topic] }
    assert_includes topics, "AI"
    assert_includes topics, "Ruby"
  end

  def test_research_deduplicates_urls_across_sources
    manager = build_manager
    source1 = MockSource.new([{ topic: "AI", findings: [{ title: "A", url: "same-url", summary: "s" }] }])
    source2 = MockSource.new([{ topic: "AI", findings: [{ title: "B", url: "same-url", summary: "s" }] }])

    manager.define_singleton_method(:enabled_sources) do
      [["src1", source1], ["src2", source2]]
    end

    results = manager.research(["AI"])
    total_findings = results.sum { |r| r[:findings].length }
    assert_equal 1, total_findings
  end

  def test_research_handles_source_failure
    manager = build_manager
    good = MockSource.new([{ topic: "AI", findings: [{ title: "A", url: "u1", summary: "s" }] }])
    bad = MockSource.new(nil, error: RuntimeError.new("API down"))

    manager.define_singleton_method(:enabled_sources) do
      [["good", good], ["bad", bad]]
    end

    results = manager.research(["AI"])
    assert_equal 1, results.length
    assert_equal 1, results.first[:findings].length
  end

  def test_research_respects_exclude_urls
    manager = build_manager(exclude_urls: Set.new(["excluded-url"]))
    source = MockSource.new([{
      topic: "AI",
      findings: [
        { title: "Excluded", url: "excluded-url", summary: "s" },
        { title: "Kept", url: "new-url", summary: "s" }
      ]
    }])

    manager.define_singleton_method(:enabled_sources) do
      [["src", source]]
    end

    results = manager.research(["AI"])
    assert_equal 1, results.first[:findings].length
    assert_equal "Kept", results.first[:findings].first[:title]
  end

  private

  def build_manager(exclude_urls: Set.new)
    SourceManager.new(source_config: {}, exclude_urls: exclude_urls)
  end

  class MockSource
    def initialize(results, error: nil)
      @results = results
      @error = error
    end

    def research(_topics, exclude_urls: Set.new)
      raise @error if @error
      @results
    end
  end
end
