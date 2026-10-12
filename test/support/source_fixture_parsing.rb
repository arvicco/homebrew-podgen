# frozen_string_literal: true

require "json"
require "sources/bluesky_source"
require "sources/hn_source"
require "sources/x_source"
require "sources/claude_web_source"

# Drives each source's real parse path from a supplied response body, with
# no network: the private request seam (request_with_retry / call_api) is
# replaced on the instance, everything downstream is the production code.
module SourceFixtureParsing
  FIXTURE_ROOT = File.join(ROOT, "test", "fixtures", "sources")
  Message = Struct.new(:content)

  def fixture_body(rel_path, root: FIXTURE_ROOT)
    JSON.parse(File.read(File.join(root, rel_path)))
  end

  def load_fixture_or_skip(rel_path)
    full = File.join(FIXTURE_ROOT, rel_path)
    skip "fixture not recorded yet: run rake fixtures:record (missing #{rel_path})" unless File.exist?(full)
    fixture_body(rel_path)
  end

  def parse_hn(body, topic: "Bitcoin", exclude: Set.new)
    src = HNSource.new(hn_queries: {topic => topic})
    src.define_singleton_method(:request_with_retry) { |**_| body }
    src.send(:search_topic, topic, exclude)
  end

  def parse_bluesky(body, topic: "Ruby programming", exclude: Set.new)
    src = BlueskySource.new
    src.define_singleton_method(:request_with_retry) { |**_| body }
    src.send(:search_topic, topic, exclude)
  end

  def parse_x(body, topic: "Ruby programming", exclude: Set.new)
    src = XSource.new
    src.define_singleton_method(:request_with_retry) { |**_| body }
    src.send(:search_topic, topic, exclude)
  end

  # body: the recorded message Hash (string keys), as the SDK would expose it.
  def parse_claude_web(body, topic: "Bitcoin ETF latest news", exclude: Set.new)
    previous = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] ||= "test-key-not-real"
    src = ClaudeWebSource.new
    message = Message.new(JSON.parse(JSON.generate(body["content"]), symbolize_names: true))
    src.define_singleton_method(:call_api) { |_topic| message }
    src.send(:search_topic, topic, exclude)
  ensure
    previous.nil? ? ENV.delete("ANTHROPIC_API_KEY") : ENV["ANTHROPIC_API_KEY"] = previous
  end

  def assert_finding_shape(findings)
    refute_empty findings, "expected at least one finding"
    findings.each do |f|
      assert_kind_of String, f[:title]
      refute_empty f[:title]
      assert_match(%r{\Ahttps?://}, f[:url])
      assert_kind_of String, f[:summary]
    end
  end
end
