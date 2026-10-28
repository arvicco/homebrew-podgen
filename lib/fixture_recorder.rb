# frozen_string_literal: true

require "json"
require "time"
require "fileutils"
require_relative "sources/bluesky_source"
require_relative "sources/hn_source"
require_relative "sources/x_source"
require_relative "sources/claude_web_source"

# Records trimmed real responses of the network sources as test fixtures
# (P1-10). NETWORK + OWNER-RUN only, via `rake fixtures:record`; never in the
# gate. The trim_* methods are pure and unit-tested offline.
class FixtureRecorder
  # The recorder's own verdict on a body; the only error whose message is
  # printed verbatim (fetch errors may carry URLs or tokens — rule 8).
  class UnusableBody < StandardError; end

  FIXTURE_DIR = File.join(__dir__, "..", "test", "fixtures", "sources")
  README = File.join(__dir__, "..", "test", "fixtures", "README.md")
  KEEP = 3
  # A fixture needs real SHAPE, not recency: the live 48 h window returned
  # zero stories on 2026-10-11 and an empty fixture was written.
  HN_RECORD_LOOKBACK_SECONDS = 30 * 86_400

  # source => [fixture path relative to FIXTURE_DIR, env keys required]
  TARGETS = {
    "hn" => ["hn/search_by_date.json", []],
    "bluesky" => ["bluesky/search_posts.json", %w[BLUESKY_HANDLE BLUESKY_APP_PASSWORD]],
    "x" => ["x/search.json", %w[SOCIALDATA_API_KEY]],
    "claude_web" => ["claude_web/message.json", %w[ANTHROPIC_API_KEY]]
  }.freeze

  def self.trim_hn(body)
    hits = Array(body["hits"]).first(KEEP).map { |h| h.reject { |k, _| k.start_with?("_") } }
    {"hits" => hits}
  end

  def self.trim_bluesky(body)
    posts = Array(body["posts"]).first(KEEP).map do |p|
      {
        "uri" => p["uri"],
        "author" => (p["author"] || {}).slice("handle", "displayName"),
        "record" => (p["record"] || {}).slice("text", "createdAt"),
        "likeCount" => p["likeCount"],
        "repostCount" => p["repostCount"]
      }
    end
    {"posts" => posts}
  end

  def self.trim_x(body)
    tweets = Array(body["tweets"]).first(KEEP).map do |t|
      t.slice("id_str", "full_text", "text", "favorite_count", "retweet_count", "tweet_created_at")
        .merge("user" => (t["user"] || {}).slice("screen_name", "name"))
    end
    {"tweets" => tweets}
  end

  # body: the Anthropic message as a plain Hash with string keys.
  def self.trim_claude_web(body)
    content = Array(body["content"]).filter_map do |b|
      case b["type"]
      when "text"
        b.slice("type", "text").merge(
          "citations" => Array(b["citations"]).first(KEEP).map { |c| c.slice("type", "url", "title", "cited_text") }
        )
      when "web_search_tool_result"
        results = b["content"].is_a?(Array) ? b["content"].first(KEEP).map { |r| r.slice("type", "url", "title") } : []
        {"type" => b["type"], "content" => results}
      end
    end
    {"role" => body["role"], "stop_reason" => body["stop_reason"], "content" => content}
  end

  # True when a trimmed body could not exercise the parse path: no items, or
  # (claude_web) a truncated answer / no text block with citations.
  def self.unusable?(name, trimmed)
    case name
    when "hn" then Array(trimmed["hits"]).empty?
    when "bluesky" then Array(trimmed["posts"]).empty?
    when "x" then Array(trimmed["tweets"]).empty?
    when "claude_web"
      trimmed["stop_reason"] != "end_turn" ||
        Array(trimmed["content"]).none? { |b| b["type"] == "text" && Array(b["citations"]).any? }
    else false
    end
  end

  # Replaces the recorded-at cell of the README row that registering `sources/<path>`.
  def self.stamp_readme(text, path, stamp)
    text.lines.map do |line|
      next line unless line.start_with?("|") && line.include?("`sources/#{path}`")
      cells = line.chomp.split("|", -1)
      cells[4] = " #{stamp} "
      "#{cells.join("|")}\n"
    end.join
  end

  def initialize(out: $stdout, fixture_dir: FIXTURE_DIR, readme: README)
    @out = out
    @fixture_dir = fixture_dir
    @readme = readme
  end

  # Records every source whose keys are present; returns names not recorded.
  def record_all
    TARGETS.filter_map do |name, (path, keys)|
      missing = keys.reject { |k| ENV[k] && !ENV[k].empty? }
      unless missing.empty?
        @out.puts format("%-11s SKIPPED (missing env: %s)", name, missing.join(", "))
        next name
      end
      trimmed = public_send(:"fetch_#{name}")
      raise UnusableBody, "unusable body (empty or truncated)" if self.class.unusable?(name, trimmed)
      write(path, trimmed)
      @out.puts format("%-11s recorded %s", name, path)
      nil
    rescue => e # skippable per-target: failed names are returned and the rake task aborts on any
      @out.puts format("%-11s FAILED (%s)", name, e.is_a?(UnusableBody) ? e.message : e.class)
      name
    end
  end

  # Each fetch_* drives the source's own private request path, so the
  # recording is the exact body the live code parses.
  def fetch_hn
    src = HNSource.new
    cutoff = (Time.now - HN_RECORD_LOOKBACK_SECONDS).to_i
    body = src.send(:request_with_retry, query: "Bitcoin", tags: "story",
      numericFilters: "created_at_i>#{cutoff}", hitsPerPage: HNSource::RESULTS_PER_TOPIC)
    self.class.trim_hn(body)
  end

  def fetch_bluesky
    src = BlueskySource.new
    src.send(:authenticate!)
    body = src.send(:request_with_retry, q: "Ruby programming",
      limit: BlueskySource::RESULTS_PER_TOPIC * 2, sort: "latest")
    self.class.trim_bluesky(body)
  end

  def fetch_x
    src = XSource.new
    body = src.send(:request_with_retry, query: "Ruby programming lang:en -is:retweet", type: "Latest")
    self.class.trim_x(body)
  end

  def fetch_claude_web
    src = ClaudeWebSource.new
    message = src.send(:call_api, "Bitcoin ETF latest news")
    raise "no response" unless message
    self.class.trim_claude_web(JSON.parse(JSON.generate(message.to_h)))
  end

  private

  def write(path, trimmed)
    full = File.join(@fixture_dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "#{JSON.pretty_generate(trimmed)}\n")
    return unless File.exist?(@readme)
    File.write(@readme, self.class.stamp_readme(File.read(@readme), path, Time.now.utc.iso8601))
  end
end
