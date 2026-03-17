# frozen_string_literal: true

require "anthropic"
require "fileutils"
require "date"
require_relative "../loggable"
require_relative "../retryable"

class Segment < Anthropic::BaseModel
  required :name, String
  required :text, String
end

class Source < Anthropic::BaseModel
  required :title, String
  required :url, String
end

class PodcastScript < Anthropic::BaseModel
  required :title, String
  required :segments, Anthropic::ArrayOf[Segment]
  required :sources, Anthropic::ArrayOf[Source]
end

class ScriptAgent
  include Loggable
  include Retryable

  MAX_RETRIES = 3

  def initialize(guidelines:, script_path:, logger: nil, priority_urls: [])
    @logger = logger
    @client = Anthropic::Client.new
    @model = ENV.fetch("CLAUDE_MODEL", "claude-opus-4-6")
    @guidelines = guidelines
    @script_path = script_path
    @priority_urls = Array(priority_urls)
  end

  # Input: array of { topic:, findings: [{ title:, url:, summary: }] }
  # Output: { title:, segments: [{ name:, text: }] }
  def generate(research_data)
    validate_research_data(research_data)
    log("Generating script with #{@model}")
    research_text = format_research(research_data)

    with_retries(max: MAX_RETRIES, on: [Anthropic::Errors::APIError]) do
      start = Time.now

      message = @client.messages.create(
        model: @model,
        max_tokens: 8192,
        system: build_system_prompt,
        messages: [
          {
            role: "user",
            content: "Write a podcast script based on this research:\n\n#{research_text}"
          }
        ],
        output_config: { format: PodcastScript }
      )

      elapsed = (Time.now - start).round(2)
      log_usage(message, elapsed)

      script = message.parsed_output
      raise "Structured output parsing failed" if script.nil?

      result = {
        title: script.title,
        segments: script.segments.map { |s| { name: s.name, text: s.text } },
        sources: script.sources.map { |s| { title: s.title, url: s.url } }
      }

      save_script_debug(result)
      result
    end
  end

  private

  def build_system_prompt
    base_prompt = <<~PROMPT
      You are an expert podcast scriptwriter. Generate a complete podcast script
      following the provided guidelines exactly.

      Each segment must have a short descriptive name that reflects its content
      (e.g. "Opening", "Bitcoin ETF Surge", "Rails 8 Authentication", "Wrap-Up").
      These names are internal labels, not read aloud — they serve as section titles.
      Do NOT use generic names like "intro", "segment_1", or "outro".

      Write naturally as spoken word — no stage directions, no timestamps, no markdown.
      Each segment's text should be the exact words the host will speak aloud.

      In the sources field, list every article or source you actually referenced in the
      script. Each source needs a short descriptive title (5-8 words max, like a headline)
      and the original URL from the research data. Only include sources whose content
      materially contributed to the script.
    PROMPT

    unless @priority_urls.empty?
      base_prompt += <<~PRIORITY

        PRIORITY LINKS: The research includes links under the "Priority links" topic
        that the producer specifically selected. You MUST cover every priority link
        in the script — do not skip any of them. Weave them naturally into the episode
        alongside the other research findings.
      PRIORITY
    end

    [
      { type: "text", text: base_prompt },
      {
        type: "text",
        text: @guidelines,
        cache_control: { type: "ephemeral" }
      }
    ]
  end

  def validate_research_data(data)
    raise ArgumentError, "Research data must be an Array, got #{data.class}" unless data.is_a?(Array)
    raise ArgumentError, "Research data is empty — nothing to script" if data.empty?

    data.each_with_index do |item, i|
      raise ArgumentError, "Research item [#{i}] must be a Hash, got #{item.class}" unless item.is_a?(Hash)
      raise ArgumentError, "Research item [#{i}] missing :topic key" unless item.key?(:topic)
      raise ArgumentError, "Research item [#{i}] :topic must be a String" unless item[:topic].is_a?(String)
      raise ArgumentError, "Research item [#{i}] missing :findings key" unless item.key?(:findings)
      raise ArgumentError, "Research item [#{i}] :findings must be an Array" unless item[:findings].is_a?(Array)

      item[:findings].each_with_index do |f, j|
        raise ArgumentError, "Finding [#{i}][#{j}] must be a Hash, got #{f.class}" unless f.is_a?(Hash)
        %i[title url summary].each do |key|
          raise ArgumentError, "Finding [#{i}][#{j}] missing :#{key} key" unless f.key?(key)
        end
      end
    end
  end

  def format_research(research_data)
    research_data.map do |item|
      findings = item[:findings].map do |f|
        "  - #{f[:title] || 'Untitled'} (#{f[:url] || 'no URL'})\n    #{f[:summary] || 'No summary available'}"
      end.join("\n")
      "## #{item[:topic] || 'Unknown topic'}\n#{findings}"
    end.join("\n\n")
  end

  def save_script_debug(script)
    FileUtils.mkdir_p(File.dirname(@script_path))

    File.open(@script_path, "w") do |f|
      f.puts "# #{script[:title]}"
      f.puts
      script[:segments].each do |seg|
        f.puts "## #{seg[:name]}"
        f.puts
        f.puts seg[:text]
        f.puts
      end
    end

    log("Script saved to #{@script_path}")
  end

  def log_usage(message, elapsed)
    usage = message.usage
    log("Script generated in #{elapsed}s (#{message.stop_reason})")
    log("  Input: #{usage.input_tokens} tokens | Output: #{usage.output_tokens} tokens")
    cache_create = usage.cache_creation_input_tokens || 0
    cache_read = usage.cache_read_input_tokens || 0
    log("  Cache create: #{cache_create} | Cache read: #{cache_read}") if cache_create > 0 || cache_read > 0
  end
end
