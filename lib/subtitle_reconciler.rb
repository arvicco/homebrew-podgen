# frozen_string_literal: true

require "anthropic"
require "json"

# Reconciles raw STT segment text with a corrected transcript using Claude.
# Preserves segment boundaries (start/end timestamps) while replacing garbled
# STT text with the corresponding portion of the reconciled transcript.
module SubtitleReconciler
  class ReconciliationError < StandardError; end

  DEFAULT_MODEL = "claude-sonnet-4-6"

  # Reconcile raw segments with a corrected transcript via Claude API.
  # Returns an array of segments with corrected text (same start/end values).
  def self.reconcile(segments, reconciled_text, api_key:, model: DEFAULT_MODEL)
    prompt = build_prompt(segments, reconciled_text)

    client = Anthropic::Client.new(api_key: api_key)
    tokens = [4096, segments.length * 80].max
    response = client.messages.create(
      model: model,
      max_tokens: tokens,
      messages: [{ role: "user", content: prompt }]
    )

    text = response.content.first.text
    result = parse_response(text)
    validate!(result, segments)
    result
  end

  # Build the prompt for Claude. Exposed for testing.
  def self.build_prompt(segments, reconciled_text)
    segments_json = JSON.pretty_generate(segments.map { |s|
      { "start" => s["start"], "end" => s["end"], "text" => s["text"] }
    })

    <<~PROMPT
      You are given raw STT segments (with timestamps) and a reconciled transcript (the correct text). Your task: produce corrected text for each segment, preserving the exact segment boundaries (same number of segments, same start/end times).

      Rules:
      - Output ONLY a JSON array of objects with "start", "end", "text" fields
      - Keep the exact same start/end values
      - Replace each segment's text with the corresponding correct text from the reconciled transcript
      - Distribute the reconciled text across segments to match what was said in each time range
      - Do not merge or split segments
      - No markdown code fences, just raw JSON

      Raw segments:
      #{segments_json}

      Reconciled transcript:
      #{reconciled_text}
    PROMPT
  end

  # Parse Claude's response into a segments array.
  def self.parse_response(text)
    # Strip markdown code fences if present
    cleaned = text.strip.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "").strip
    JSON.parse(cleaned)
  rescue JSON::ParserError => e
    raise ReconciliationError, "Failed to parse reconciled segments: #{e.message}"
  end

  # Validate that reconciled segments match original structure.
  def self.validate!(reconciled, original)
    unless reconciled.length == original.length
      raise ReconciliationError, "Segment count mismatch: expected #{original.length}, got #{reconciled.length}"
    end

    reconciled.each_with_index do |seg, i|
      orig = original[i]
      unless seg["start"] == orig["start"] && seg["end"] == orig["end"]
        raise ReconciliationError, "Timestamp mismatch at segment #{i}: " \
          "expected #{orig['start']}-#{orig['end']}, got #{seg['start']}-#{seg['end']}"
      end
    end
  end
end
