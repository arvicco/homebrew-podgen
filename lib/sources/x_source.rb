# frozen_string_literal: true

require "httparty"
require_relative "base_source"

class XSource < BaseSource
  RESULTS_PER_TOPIC = 5
  API_BASE = "https://api.socialdata.tools/twitter/search"

  def initialize(logger: nil, priority_handles: [], **_options)
    super(logger: logger)
    @api_key = ENV["SOCIALDATA_API_KEY"]
    @priority_handles = priority_handles.map { |h| h.delete_prefix("@") }
  end

  private

  def available?
    !!@api_key
  end

  def search_topic(topic, exclude_urls)
    seen_urls = exclude_urls.dup
    findings = []

    # Phase 1: Priority accounts — search their tweets first
    if @priority_handles.any?
      from_clause = @priority_handles.map { |h| "from:#{h}" }.join(" OR ")
      priority_query = "(#{from_clause}) #{topic} -is:retweet"

      priority_tweets = fetch_tweets(priority_query)
      priority_findings = parse_tweets(priority_tweets, seen_urls)
      findings.concat(priority_findings)

      log("Priority accounts returned #{priority_findings.length} results for '#{topic}'") if priority_findings.any?
    end

    # Phase 2: General search — fill remaining slots
    remaining = RESULTS_PER_TOPIC - findings.length
    if remaining > 0
      general_query = "#{topic} lang:en -is:retweet"
      general_tweets = fetch_tweets(general_query)
      general_findings = parse_tweets(general_tweets, seen_urls)
      findings.concat(general_findings.first(remaining))
    end

    findings
  rescue => e
    log("Failed to search X for '#{topic}': #{e.message}")
    []
  end

  def fetch_tweets(query)
    response = request_with_retry(query: query, type: "Latest")
    tweets = response["tweets"]
    tweets.is_a?(Array) ? tweets : []
  end

  def parse_tweets(tweets, seen_urls)
    tweets.filter_map do |tweet|
      text = tweet["full_text"].to_s.strip
      text = tweet["text"].to_s.strip if text.empty?
      next if text.empty?

      user = tweet["user"] || {}
      screen_name = user["screen_name"] || "unknown"
      tweet_id = tweet["id_str"] || tweet["id"].to_s

      tweet_url = "https://x.com/#{screen_name}/status/#{tweet_id}"
      next if seen_urls.include?(tweet_url)

      seen_urls.add(tweet_url)

      # Use first line or first 120 chars as title
      title = text.lines.first.to_s.strip
      title = "#{title[0, 117]}..." if title.length > 120

      # Full text as summary, capped at 500 chars
      summary = text.length > 500 ? "#{text[0, 497]}..." : text

      favorites = tweet["favorite_count"] || 0
      retweets = tweet["retweet_count"] || 0
      summary = "#{summary} [#{favorites} likes, #{retweets} retweets on X]"

      {
        title: "@#{screen_name}: #{title}",
        url: tweet_url,
        summary: summary
      }
    end
  end

  def request_with_retry(**params)
    with_retries(max: MAX_RETRIES, label: source_name) do
      response = HTTParty.get(
        API_BASE,
        query: params,
        headers: {
          "Authorization" => "Bearer #{@api_key}",
          "Accept" => "application/json"
        },
        timeout: 15
      )
      raise "HTTP #{response.code} from SocialData API" unless response.success?
      response.parsed_response
    end
  end
end
