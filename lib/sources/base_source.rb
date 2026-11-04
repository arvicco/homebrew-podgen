# frozen_string_literal: true

require "set"
require "httparty"
require_relative "../loggable"
require_relative "../http_retryable"

# Template base class for topic-based research sources.
# Subclasses implement search_topic and optionally override available?.
class BaseSource
  include Loggable
  include HttpRetryable

  MAX_RETRIES = 2

  def initialize(logger: nil, **_options)
    @logger = logger
  end

  # Iterates topics, calls search_topic, logs timing.
  # Returns: [{ topic: String, findings: [{ title:, url:, summary: }] }]
  def research(topics, exclude_urls: Set.new)
    return empty_results(topics) unless available?

    topics.map do |topic|
      log("Searching #{source_name}: #{topic}")
      start = Time.now
      findings = search_topic(topic, exclude_urls)
      elapsed = (Time.now - start).round(2)
      log("#{source_name} found #{findings.length} results for '#{topic}' (#{elapsed}s)")
      { topic: topic, findings: findings }
    end
  end

  private

  def source_name
    self.class.name
  end

  # GET +url+ and return the parsed body; 429/5xx and the shared transient
  # network errors (HTTP_EXCEPTIONS) are retried, any other non-success
  # (a 401 from a revoked key, a 400) raises "HTTP <code> from <source>"
  # on the first attempt.
  def get_json(url, query:, timeout: 15, headers: {})
    with_http_retries(source_name, max: MAX_RETRIES, on: HTTP_EXCEPTIONS) do
      response = HTTParty.get(url, query: query, headers: headers, timeout: timeout)
      unless response.success?
        message = "HTTP #{response.code} from #{source_name}"
        raise RetriableError, message if RETRIABLE_CODES.include?(response.code)
        raise message
      end
      response.parsed_response
    end
  end

  def available?
    true
  end

  def search_topic(_topic, _exclude_urls)
    raise NotImplementedError, "#{self.class}#search_topic must be implemented"
  end

  def empty_results(topics)
    topics.map { |t| { topic: t, findings: [] } }
  end
end
