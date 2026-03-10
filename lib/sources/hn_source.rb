# frozen_string_literal: true

require "httparty"
require_relative "base_source"

class HNSource < BaseSource
  RESULTS_PER_TOPIC = 3
  LOOKBACK_HOURS = 48
  API_BASE = "https://hn.algolia.com/api/v1/search_by_date"

  private

  def search_topic(topic, exclude_urls)
    cutoff_timestamp = (Time.now - (LOOKBACK_HOURS * 3600)).to_i

    response = request_with_retry(
      query: topic,
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
  rescue => e
    log("Failed to search HN for '#{topic}': #{e.message}")
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
