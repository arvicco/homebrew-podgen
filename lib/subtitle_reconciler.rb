# frozen_string_literal: true

require "anthropic"
require_relative "anthropic_client"
require_relative "claude_models"
require_relative "loggable"
require_relative "usage_logger"
require "json"

# Reconciles raw STT segment text with a corrected transcript using Claude.
# Preserves segment boundaries (start/end timestamps) while replacing garbled
# STT text with the corresponding portion of the reconciled transcript.
module SubtitleReconciler
  class ReconciliationError < StandardError; end

  # Seconds of tolerated drift between original and LLM-returned timestamps.
  TIMESTAMP_EPSILON = 0.01

  # Output cap (P17-2, I-12): the answer repeats every segment's start/end
  # plus the reconciled text, and diacritic-heavy languages tokenise at ~2
  # chars/token, so the cap is sized from the content: ~40 tokens of
  # structure per segment + 0.8 tokens per char of segment and transcript
  # text, floored at MIN_TOKENS. MAX_TOKENS_CEILING keeps every request
  # (including the doubled retry) inside what the model can emit within
  # AnthropicClient::REQUEST_TIMEOUT (300 s): a 20k-token answer is the
  # most a non-streaming call completes in that window. The I-12 episode
  # (65 segments, 6043 chars) needs ~12k; its doubled retry still fits.
  MIN_TOKENS = 4096
  MAX_TOKENS_CEILING = 20_000

  # Usage logging (P8-2) through the ambient logger; private singletons, so
  # the module's public surface is unchanged.
  class << self
    include Loggable
    include UsageLogger

    private

    # Loggable tags with the receiver's class (Module here); name the module.
    def log(message) = logger_target.log("[SubtitleReconciler] #{message}")
  end

  # Reconcile raw segments with a corrected transcript via Claude API.
  # Returns an array of segments with corrected text (same start/end values).
  # The result is built from the ORIGINAL segments (P4-1): their exact
  # start/end values and keys, with only "text" taken from the model. Drift
  # within TIMESTAMP_EPSILON is validated but never persisted, and keys the
  # model invents (e.g. "speaker") are dropped — the *_timestamps.json
  # sidecar schema is frozen.
  def self.reconcile(segments, reconciled_text, api_key:, model: nil)
    model ||= ClaudeModels.for(:subtitle_reconciler)
    client = Anthropic::Client.new(api_key: api_key, timeout: AnthropicClient::REQUEST_TIMEOUT)
    tokens = token_cap(segments, reconciled_text)
    mismatch = nil
    retried_truncation = false

    # Bounded (P17-2): one retry with the cap doubled after a max_tokens
    # stop (a truncated body is never parsed), one retry naming the count
    # mismatch; a repeat of either raises.
    loop do
      response = request(client, model, build_prompt(segments, reconciled_text, mismatch: mismatch), tokens)

      if response.stop_reason.to_s == "max_tokens"
        doubled = [tokens * 2, MAX_TOKENS_CEILING].min
        if retried_truncation || doubled <= tokens
          raise ReconciliationError, "Reconciliation output stopped at max_tokens (cap #{tokens}) " \
            "for #{segments.length} segments"
        end
        log("Retrying: output stopped at max_tokens (cap #{tokens}); retrying once with cap #{doubled}")
        retried_truncation = true
        tokens = doubled
        next
      end

      result = parse_response(AnthropicClient.text_of(response))
      if result.is_a?(Array) && result.length != segments.length && mismatch.nil?
        mismatch = "Segment count mismatch: expected #{segments.length}, got #{result.length}"
        log("Retrying: #{mismatch}; retrying once with the mismatch named")
        next
      end

      validate!(result, segments)
      return segments.each_with_index.map { |orig, i| orig.merge("text" => result[i]["text"]) }
    end
  end

  # Output token cap sized from the content (see MIN_TOKENS).
  def self.token_cap(segments, reconciled_text)
    chars = segments.sum { |s| s["text"].to_s.length } + reconciled_text.to_s.length
    (segments.length * 40 + chars * 0.8).ceil.clamp(MIN_TOKENS, MAX_TOKENS_CEILING)
  end

  def self.request(client, model, prompt, tokens)
    response, elapsed = measure_time do
      client.messages.create(
        model: model,
        max_tokens: tokens,
        messages: [{ role: "user", content: prompt }],
        **AnthropicClient.effort_params(:subtitle_reconciler)
      )
    end
    log_api_usage("Subtitles reconciled", response, elapsed)
    response
  end
  private_class_method :request

  # Build the prompt for Claude. Exposed for testing. `mismatch` names the
  # previous answer's segment-count error on the one retry.
  def self.build_prompt(segments, reconciled_text, mismatch: nil)
    segments_json = JSON.pretty_generate(segments.map { |s|
      { "start" => s["start"], "end" => s["end"], "text" => s["text"] }
    })

    prompt = <<~PROMPT
      You are given raw STT segments (with timestamps) and a reconciled transcript (the correct text). Your task: produce corrected text for each segment, preserving the exact segment boundaries (same number of segments, same start/end times).

      Rules:
      - Output ONLY a JSON array of objects with "start", "end", "text" fields
      - Keep the exact same start/end values
      - Replace each segment's text with the corresponding correct text from the reconciled transcript
      - Distribute the reconciled text across segments to match what was said in each time range
      - Do not merge or split segments
      - No markdown code fences, just raw JSON
      - Output compact JSON on one line: no indentation, no line breaks, no spaces between tokens
      - Escape every double-quote character that appears inside a "text" value as \\" — never break out of the string. Dialogue passages in the transcript may contain literal " marks; those MUST be escaped.

      Raw segments:
      #{segments_json}

      Reconciled transcript:
      #{reconciled_text}
    PROMPT
    return prompt unless mismatch

    prompt + "\nYour previous answer was rejected: #{mismatch}. " \
      "Return exactly #{segments.length} objects, one per raw segment, in order.\n"
  end

  # Parse Claude's response into a segments array.
  def self.parse_response(text)
    # Strip markdown code fences if present
    cleaned = text.strip.sub(/\A```(?:json)?\s*/, "").sub(/\s*```\z/, "").strip
    begin
      JSON.parse(cleaned)
    rescue JSON::ParserError => e
      begin
        JSON.parse(repair_json(cleaned))
      rescue JSON::ParserError
        raise ReconciliationError, "Failed to parse reconciled segments: #{e.message}"
      end
    end
  end

  # One repair pass for a model that left a literal `"` unescaped inside a
  # string value (P17-2, seen as `got: 'powiedział."'`): inside a string, a
  # `"` whose next non-space character is not structural (`,` `:` `}` `]`
  # or the end) cannot be the closing quote, so it is escaped. In valid
  # JSON every unescaped in-string `"` closes the string and is followed by
  # a structural character, so valid JSON passes through unchanged.
  # One pass over a chars array: String#[] by index and a slice of the rest
  # per `"` made it quadratic on non-ASCII text (Q-157).
  def self.repair_json(text)
    chars = text.chars
    out = +""
    in_string = false
    i = 0
    while i < chars.length
      c = chars[i]
      if in_string && c == "\\"
        out << c << chars[i + 1].to_s
        i += 2
        next
      end
      if c == '"'
        if !in_string
          in_string = true
        elsif structural_next?(chars, i + 1)
          in_string = false
        else
          out << "\\"
        end
      end
      out << c
      i += 1
    end
    out
  end

  # Is the next non-space character from j structural (`,` `:` `}` `]`) or the end?
  def self.structural_next?(chars, j)
    j += 1 while j < chars.length && chars[j].match?(/\s/)
    j == chars.length || ",:}]".include?(chars[j])
  end
  private_class_method :structural_next?

  # LLM round-trips can re-serialize floats (7.7 -> 7.700000001).
  def self.close_enough?(a, b)
    return a == b unless a.is_a?(Numeric) && b.is_a?(Numeric)
    (a - b).abs <= TIMESTAMP_EPSILON
  end

  # Validate that reconciled segments match original structure.
  def self.validate!(reconciled, original)
    unless reconciled.length == original.length
      raise ReconciliationError, "Segment count mismatch: expected #{original.length}, got #{reconciled.length}"
    end

    reconciled.each_with_index do |seg, i|
      unless seg.is_a?(Hash) && seg["text"].is_a?(String)
        raise ReconciliationError, "Segment #{i} has no text string"
      end
      orig = original[i]
      unless close_enough?(seg["start"], orig["start"]) && close_enough?(seg["end"], orig["end"])
        raise ReconciliationError, "Timestamp mismatch at segment #{i}: " \
          "expected #{orig['start']}-#{orig['end']}, got #{seg['start']}-#{seg['end']}"
      end
    end
  end
end
