# frozen_string_literal: true

require "date"
require_relative "../anthropic_client"
require_relative "../loggable"
require_relative "../retryable"
require_relative "../usage_logger"

class TopicQuery < Anthropic::BaseModel
  required :query, String
  optional :hn_query, String # P3-1: 2-4 keywords for Hacker News (Algolia ANDs every term)
end

class TopicList < Anthropic::BaseModel
  required :queries, Anthropic::ArrayOf[TopicQuery]
end

class TopicAgent
  include AnthropicClient
  include Loggable
  include Retryable
  include UsageLogger

  MAX_RETRIES = 3
  HN_QUERY_MAX_WORDS = 4

  # P3-1: topic string => short HN keyword query (nil when the model gave none).
  # Filled by #generate; empty until then.
  attr_reader :hn_queries

  def initialize(guidelines:, recent_topics: nil, logger: nil)
    @logger = logger
    init_anthropic_client(role: :topic)
    @guidelines = guidelines
    @recent_topics = recent_topics
    @hn_queries = {}
  end

  # Output: array of topic query strings (same format ResearchAgent expects)
  def generate
    log("Generating topics with #{@model}")
    today = Date.today.strftime("%A, %B %-d, %Y (%Y-%m-%d)")

    with_retries(max: MAX_RETRIES, on: [Anthropic::Errors::APIError, StructuredOutputError]) do
      message, elapsed = measure_time do
        @client.messages.create(
          model: @model,
          max_tokens: 1024,
          system: build_system_prompt,
          messages: [
            {
              role: "user",
              content: build_user_prompt(today)
            }
          ],
          **AnthropicClient.effort_params(:topic, format: TopicList)
        )
      end

      log_api_usage("Topics generated", message, elapsed)

      result = require_parsed_output!(message, TopicList)

      queries = result.queries.map(&:query)
      @hn_queries = result.queries.to_h { |t| [t.query, short_hn_query(t.hn_query)] }
      queries.each { |q| log("  → #{q}") }
      queries
    end
  end

  private

  def short_hn_query(raw)
    words = raw.to_s.split.first(HN_QUERY_MAX_WORDS)
    words.empty? ? nil : words.join(" ")
  end

  def build_user_prompt(today)
    prompt = "Today's date is #{today}. Generate 4 specific, timely search queries for this podcast episode."
    if @recent_topics && !@recent_topics.empty?
      prompt += "\n\nIMPORTANT: The following topics were already covered in recent episodes.\n" \
                "Generate queries about DIFFERENT subjects — do not repeat these:\n" \
                "#{@recent_topics}"
    end
    prompt
  end

  def build_system_prompt
    [
      {
        type: "text",
        text: <<~PROMPT
          You are a podcast producer generating search queries for today's episode.
          Based on the podcast guidelines below and today's date, generate exactly 4
          specific, timely search queries that would find the most interesting recent
          news for each topic area defined in the guidelines.

          Each query should be:
          - Specific enough to return focused, relevant results
          - Time-aware (reference this week, recent events, or current trends)
          - Aligned with the podcast's topic areas and editorial voice
          - Different from each other, covering distinct topic areas from the guidelines

          For each query also give hn_query: the topic's 2-4 defining keywords (proper nouns first, no dates or filler words), used as a Hacker News keyword search.
        PROMPT
      },
      {
        type: "text",
        text: @guidelines,
        cache_control: { type: "ephemeral" }
      }
    ]
  end

end
