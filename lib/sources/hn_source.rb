# frozen_string_literal: true

require "httparty"
require_relative "base_source"

class HNSource < BaseSource
  RESULTS_PER_TOPIC = 3
  LOOKBACK_HOURS = 48
  API_BASE = "https://hn.algolia.com/api/v1/search_by_date"
  SHORT_TOPIC_WORDS = 4

  # hn_queries: topic string => short keyword query (P3-1). Algolia ANDs
  # every term, so a full research topic never matches; topics without a
  # keyword query are skipped rather than sent, unless the topic itself is
  # short enough to serve as the query (queue.yml fallback topics).
  def initialize(hn_queries: {}, **options)
    super(**options)
    @hn_queries = hn_queries || {}
  end

  private

  def search_topic(topic, exclude_urls)
    keywords = @hn_queries[topic].to_s.strip
    keywords = topic.to_s.strip if keywords.empty? && topic.to_s.split.size <= SHORT_TOPIC_WORDS
    if keywords.empty?
      log("no hn_query for '#{topic}' — skipped")
      return []
    end
    log("HN query for '#{topic}': #{keywords}")

    cutoff_timestamp = (Time.now - (LOOKBACK_HOURS * 3600)).to_i

    response = request_with_retry(
      query: keywords,
      tags: "story",
      numericFilters: "created_at_i>#{cutoff_timestamp}",
      hitsPerPage: RESULTS_PER_TOPIC
    )

    return [] unless response && response["hits"]

    response["hits"].filter_map do |hit|
      title = hit["title"].to_s.strip
      next if title.empty?

      url = hit["url"]
      url = "https://news.ycombinator.com/item?id=#{hit['objectID']}" if url.nil? || url.empty?

      next if exclude_urls.include?(url)

      points = hit["points"] || 0
      comments = hit["num_comments"] || 0

      {
        title: title,
        url: url,
        summary: "#{points} points, #{comments} comments on Hacker News"
      }
    end
  rescue => e # skippable: one source down; the other sources still feed research
    log("Failed to search HN for '#{topic}': #{e.class}: #{e.message}")
    []
  end

  def request_with_retry(**params)
    with_retries(max: MAX_RETRIES, label: source_name) do
      response = HTTParty.get(API_BASE, query: params, timeout: 15)
      raise "HTTP #{response.code} from HN Algolia API" unless response.success?
      response.parsed_response
    end
  end
end
