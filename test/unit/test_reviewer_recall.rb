# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../../scripts/reviewer_recall"

# P18-9 (Q-138): the offline half of the blocker-recall measurement — bundle
# loading, the effort each call sends, token capture, the table. The live
# reviewer calls run only through `podgen test reviewer_recall`.
class TestReviewerRecall < Minitest::Test
  Usage = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)
  Message = Struct.new(:parsed_output, :stop_reason, :usage, :model, :content)

  class FakeClient
    attr_reader :calls

    def initialize(reviews)
      @reviews = reviews
      @calls = []
    end

    def messages = self

    def create(**kwargs)
      @calls << kwargs
      Message.new(@reviews.fetch(@calls.size - 1), "end_turn", Usage.new(23_000, 2_000, 0, 0), "m", [])
    end
  end

  def setup
    @dir = Dir.mktmpdir("reviewer_recall")
    @saved_effort = ENV.delete("CLAUDE_EFFORT_REVIEWER")
  end

  def teardown
    FileUtils.rm_rf(@dir)
    @saved_effort ? ENV["CLAUDE_EFFORT_REVIEWER"] = @saved_effort : ENV.delete("CLAUDE_EFFORT_REVIEWER")
  end

  def test_measure_reviews_at_low_and_compares_with_default_issues
    path = write_bundle("fn-2026-10-17", default_issues: [{severity: "BLOCKER", check: "h", segment: "s", message: "95%"}])
    client = FakeClient.new([review("BLOCKER", "WARNING")])

    rows = ReviewerRecall.measure([path], client: client)

    assert_equal 1, client.calls.size
    assert_equal :low, client.calls.first.dig(:output_config, :effort)
    row = rows.first
    assert_equal ["fn-2026-10-17", 1, 1, 23_000, 2_000],
      [row.name, row.default_blockers, row.low_blockers, row.input_tokens, row.output_tokens]
    assert_nil ENV["CLAUDE_EFFORT_REVIEWER"], "the override does not outlive the call"
  end

  def test_measure_rerun_default_sends_no_effort_first
    path = write_bundle("b", default_issues: [])
    client = FakeClient.new([review("BLOCKER"), review])

    rows = ReviewerRecall.measure([path], rerun_default: true, client: client)

    assert_nil client.calls[0].dig(:output_config, :effort)
    assert_equal :low, client.calls[1].dig(:output_config, :effort)
    assert_equal [1, 0], [rows.first.default_blockers, rows.first.low_blockers]
  end

  def test_table_reports_episode_level_recall
    rows = [
      ReviewerRecall::Row.new(name: "a", default_blockers: 2, low_blockers: 1, input_tokens: 1, output_tokens: 1),
      ReviewerRecall::Row.new(name: "b", default_blockers: 1, low_blockers: 0, input_tokens: 1, output_tokens: 1),
      ReviewerRecall::Row.new(name: "c", default_blockers: 0, low_blockers: 1, input_tokens: 1, output_tokens: 1)
    ]

    lines = ReviewerRecall.table(rows)

    assert_includes lines.last, "recall at low: 1/2"
    assert_includes lines.last, "BLOCKERs 1 low vs 3 default"
  end

  def test_load_bundle_without_research_is_refused
    path = File.join(@dir, "x.json")
    File.write(path, JSON.generate({date: "2026-10-17", script: {title: "t", segments: []}}))

    error = assert_raises(ArgumentError) { ReviewerRecall.load_bundle(path) }
    assert_includes error.message, "research_data"
  end

  private

  def review(*severities)
    issues = severities.map { |s| ReviewIssue.new(severity: s, check: "c", segment: "s", message: "m") }
    ScriptReview.new(issues: issues, overall_assessment: "ok")
  end

  def write_bundle(name, default_issues:)
    path = File.join(@dir, "#{name}.json")
    File.write(path, JSON.generate({
      name: name, date: "2026-10-17",
      script: {title: "T", segments: [{name: "Opening", text: "Strategy holds 95% in bitcoin."}], sources: []},
      research_data: [{topic: "BTC", findings: [{title: "f", url: "https://x", summary: "s"}]}],
      priority_urls: [], default_issues: default_issues
    }))
    path
  end
end
