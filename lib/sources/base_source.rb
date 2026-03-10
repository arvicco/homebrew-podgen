# frozen_string_literal: true

require "set"
require_relative "../loggable"
require_relative "../retryable"

# Template base class for topic-based research sources.
# Subclasses implement search_topic and optionally override available?.
class BaseSource
  include Loggable
  include Retryable

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
