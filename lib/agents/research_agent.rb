# frozen_string_literal: true

require "exa-ai"
require "set"
require_relative "../loggable"
require_relative "../http_retryable"

class ResearchAgent
  include Loggable
  include HttpRetryable

  MAX_RETRIES = 3
  RESULTS_PER_TOPIC = 5
  # exa-ai raises its own classes only from HTTP responses; a timeout or a
  # failed connection arrives as Faraday's (Q-99). All four are transient.
  RETRIABLE_ERRORS = [Exa::TooManyRequests, Exa::ServerError, Faraday::TimeoutError, Faraday::ConnectionFailed].freeze

  def initialize(results_per_topic: RESULTS_PER_TOPIC, exclude_urls: Set.new, category: "news", logger: nil)
    @results_per_topic = results_per_topic
    @exclude_urls = exclude_urls
    @category = category
    @logger = logger

    Exa.configure do |config|
      config.api_key = ENV.fetch("EXA_API_KEY") {
        raise "EXA_API_KEY environment variable is not set"
      }
    end
    @client = Exa::Client.new(timeout: 30)
  end

  # Input: array of topic strings
  # Output: array of { topic:, findings: [{ title:, url:, summary: }] }
  def research(topics, exclude_urls: nil)
    effective_excludes = exclude_urls ? (@exclude_urls | exclude_urls) : @exclude_urls
    topics.map do |topic|
      log("Researching: #{topic}")
      start = Time.now
      findings = search_topic(topic, effective_excludes)
      elapsed = (Time.now - start).round(2)
      log("Found #{findings.length} results for '#{topic}' (#{elapsed}s)")
      { topic: topic, findings: findings }
    end
  end

  private

  def search_topic(topic, exclude_urls = @exclude_urls)
    results = search_with_retry(
      topic,
      num_results: @results_per_topic,
      type: "auto",
      category: @category,
      summary: { query: "Summarize this article's key points for a podcast segment" },
      start_published_date: (Date.today - 7).iso8601
    )

    all = results.results.map do |r|
      {
        title: r["title"],
        url: r["url"],
        summary: r["summary"]
      }
    end

    if exclude_urls.any?
      before = all.length
      all.reject! { |r| exclude_urls.include?(r[:url]) }
      filtered = before - all.length
      log("Filtered #{filtered} previously-used URL(s) for '#{topic}'") if filtered > 0
    end

    all
  rescue Exa::Error, Faraday::Error => e
    # The topic is skipped with a counted warning; the other topics proceed.
    log_warning("Failed to research '#{topic}' after #{MAX_RETRIES} attempts: #{e.class}: #{e.message}")
    []
  end

  def search_with_retry(query, **params)
    with_http_retries("ResearchAgent", max: MAX_RETRIES, on: RETRIABLE_ERRORS, reraise: true) do
      @client.search(query, **params)
    end
  end
end
