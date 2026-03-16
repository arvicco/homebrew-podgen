# frozen_string_literal: true

require "anthropic"
require "json"
require_relative "loggable"
require_relative "retryable"

class VocabularyAnnotator
  include Loggable
  include Retryable

  CEFR_LEVELS = %w[A1 A2 B1 B2 C1 C2].freeze

  def initialize(api_key, model: "claude-sonnet-4-6", logger: nil)
    @logger = logger
    @client = Anthropic::Client.new(api_key: api_key)
    @model = model
  end

  # Returns [marked_body, vocabulary_md]
  # marked_body: transcript with first occurrence of vocab words bolded
  # vocabulary_md: markdown vocabulary section (empty string if no words found)
  def annotate(text, language:, cutoff:)
    cutoff = cutoff.upcase
    unless CEFR_LEVELS.include?(cutoff)
      raise ArgumentError, "Invalid CEFR level: #{cutoff}. Must be one of: #{CEFR_LEVELS.join(', ')}"
    end

    log("Annotating vocabulary (#{language}, #{cutoff}+ cutoff)")
    entries = classify_words(text, language, cutoff)

    if entries.empty?
      log("No vocabulary words found at #{cutoff}+ level")
      return [text, ""]
    end

    log("Found #{entries.length} vocabulary words at #{cutoff}+ level")
    marked_body = mark_words(text, entries)
    vocabulary_md = build_vocabulary_section(entries)

    [marked_body, vocabulary_md]
  end

  private

  def classify_words(text, language, cutoff)
    with_retries(max: 3, on: [Anthropic::Errors::APIError]) do
      start = Time.now

      message = @client.messages.create(
        model: @model,
        max_tokens: 8192,
        system: system_prompt(language, cutoff),
        messages: [
          { role: "user", content: text }
        ]
      )

      elapsed = (Time.now - start).round(2)
      log_usage(message, elapsed)

      raw = message.content.first.text.strip
      # Extract JSON array from response (may be wrapped in ```json ... ```)
      json_str = raw[/\[.*\]/m]
      return [] unless json_str

      entries = JSON.parse(json_str, symbolize_names: true)
      return [] unless entries.is_a?(Array)

      # Validate and normalize entries
      entries.select { |e| valid_entry?(e, cutoff) }
    end
  end

  def system_prompt(language, cutoff)
    <<~PROMPT
      Given this #{language} text, identify all unique words at CEFR level #{cutoff} or above.
      For each word, provide:
      - word: the word as it appears in text
      - lemma: dictionary form (infinitive for verbs, nominative singular masculine for adjectives, nominative singular for nouns)
      - level: CEFR level (A1/A2/B1/B2/C1/C2)
      - pos: part of speech (noun, verb, adj, adv, etc.)
      - translation: English translation (concise, context-appropriate)
      - definition: brief dictionary-style definition in English (1 sentence)

      Return a JSON array. Only include words at #{cutoff} or above.
      Do not include proper nouns, numbers, or punctuation.
      If a word appears in multiple forms, include the most representative occurrence.
      Return ONLY the JSON array, no other text.
    PROMPT
  end

  def valid_entry?(entry, cutoff)
    return false unless entry.is_a?(Hash)
    return false unless entry[:word] && entry[:lemma] && entry[:level]
    return false unless CEFR_LEVELS.include?(entry[:level])

    cutoff_idx = CEFR_LEVELS.index(cutoff)
    entry_idx = CEFR_LEVELS.index(entry[:level])
    entry_idx >= cutoff_idx
  end

  def mark_words(text, entries)
    # Build a set of words to mark (case-insensitive matching)
    word_map = {}
    entries.each do |entry|
      word_map[entry[:word].downcase] = true
    end

    marked = text.dup
    marked_words = {}

    # Mark first occurrence of each word (word-boundary match)
    entries.each do |entry|
      word = entry[:word]
      next if marked_words[word.downcase]

      # Match the word at word boundaries, case-insensitive, first occurrence only
      pattern = /(?<!\*)\b(#{Regexp.escape(word)})\b(?!\*)/i
      if marked.match?(pattern)
        marked.sub!(pattern, '**\1**')
        marked_words[word.downcase] = true
      end
    end

    marked
  end

  def build_vocabulary_section(entries)
    # Sort by CEFR level (hardest first), then alphabetically by lemma
    sorted = entries.sort_by do |e|
      [-CEFR_LEVELS.index(e[:level]), e[:lemma].to_s.downcase]
    end

    # Group by level
    grouped = sorted.group_by { |e| e[:level] }

    lines = ["## Vocabulary", ""]
    CEFR_LEVELS.reverse_each do |level|
      next unless grouped[level]

      lines << "**#{level}**"
      grouped[level].each do |entry|
        line = "- **#{entry[:lemma]}** (#{entry[:pos]})"
        line += " — #{entry[:translation]}" if entry[:translation]
        line += ". #{entry[:definition]}" if entry[:definition]
        # Show original form if different from lemma
        if entry[:word].downcase != entry[:lemma].downcase
          line += " _Original: #{entry[:word]}_"
        end
        lines << line
      end
      lines << ""
    end

    lines.join("\n").strip
  end

  def log_usage(message, elapsed)
    usage = message.usage
    log("Vocabulary classified in #{elapsed}s (#{message.stop_reason})")
    log("  Input: #{usage.input_tokens} tokens | Output: #{usage.output_tokens} tokens")
  end
end
