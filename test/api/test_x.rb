# frozen_string_literal: true

require_relative "../test_helper"
require "sources/x_source"

class TestXSource < Minitest::Test
  def setup
    skip_unless_env("SOCIALDATA_API_KEY")
    @source = XSource.new
    @topics = ["Ruby programming", "Bitcoin"]
  end

  def test_research_returns_results
    results = @source.research(@topics)

    assert_kind_of Array, results
    refute_empty results
    results.each do |entry|
      assert entry[:topic], "entry must have :topic"
      assert_kind_of Array, entry[:findings]
      entry[:findings].each do |f|
        assert f[:title], "finding must have :title"
        assert f[:url], "finding must have :url"
      end
    end
  end

  def test_research_returns_findings
    results = @source.research(@topics)
    total = results.sum { |r| r[:findings].length }
    assert total > 0, "Expected at least 1 finding"
  end
end
