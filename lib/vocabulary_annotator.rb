# frozen_string_literal: true

require "anthropic"
require "json"
require "set"
require_relative "loggable"
require_relative "retryable"
require_relative "usage_logger"
require_relative "tell/espeak"

class VocabularyAnnotator
  include Loggable
  include Retryable
  include UsageLogger

  CEFR_LEVELS = %w[A1 A2 B1 B2 C1 C2].freeze

  def initialize(api_key, model: "claude-sonnet-4-6", logger: nil)
    @logger = logger
    @client = Anthropic::Client.new(api_key: api_key)
    @model = model
  end

  # Returns [marked_body, vocabulary_md]
  # marked_body: transcript with first occurrence of vocab words bolded
  # vocabulary_md: markdown vocabulary section (empty string if no words found)
  def annotate(text, language:, cutoff:, known_lemmas: Set.new, max: nil, filters: {})
    cutoff = cutoff.upcase
    unless CEFR_LEVELS.include?(cutoff)
      raise ArgumentError, "Invalid CEFR level: #{cutoff}. Must be one of: #{CEFR_LEVELS.join(', ')}"
    end

    log("Annotating vocabulary (#{language}, #{cutoff}+ cutoff)")
    entries = classify_words(text, language, cutoff, filters)
    unless known_lemmas.empty?
      before = entries.length
      entries.reject! { |e| known_lemmas.include?(e[:lemma].to_s.downcase) }
      filtered = before - entries.length
      log("Filtered #{filtered} known words") if filtered > 0
    end

    if entries.empty?
      log("No vocabulary words found at #{cutoff}+ level")
      return [text, ""]
    end

    # Cap after known-word filtering so max applies to the final set
    if max && entries.length > max
      # Keep hardest words (highest CEFR level first, then alphabetical)
      entries.sort_by! { |e| [-CEFR_LEVELS.index(e[:level]), e[:lemma].to_s.downcase] }
      entries = entries.first(max)
      log("Capped to #{max} entries (keeping hardest)")
    end

    log("Found #{entries.length} vocabulary words at #{cutoff}+ level")
    add_ipa(entries, language)
    marked_body = mark_words(text, entries)
    vocabulary_md = build_vocabulary_section(entries)

    [marked_body, vocabulary_md]
  end

  private

  def classify_words(text, language, cutoff, filters = {})
    with_retries(max: 3, on: [Anthropic::Errors::APIError]) do
      message, elapsed = measure_time do
        @client.messages.create(
          model: @model,
          max_tokens: 16384,
          system: system_prompt(language, cutoff, filters),
          messages: [
            { role: "user", content: text }
          ]
        )
      end

      log_api_usage("Vocabulary classified", message, elapsed)

      raw = message.content.first.text.strip
      # Extract JSON array from response (may be wrapped in ```json ... ```)
      json_str = raw[/\[.*\]/m]

      # When response is truncated (max_tokens), salvage partial JSON
      if json_str.nil? && message.stop_reason == "max_tokens"
        json_str = salvage_truncated_json(raw)
        log("Salvaged partial JSON from truncated response") if json_str
      end

      return [] unless json_str

      entries = JSON.parse(json_str, symbolize_names: true)
      return [] unless entries.is_a?(Array)

      # Validate and normalize entries
      entries.select { |e| valid_entry?(e, cutoff) }
    end
  end

  def add_ipa(entries, language)
    if Tell::Espeak.supports?(language)
      entries.each do |entry|
        ipa = Tell::Espeak.ipa(entry[:lemma], lang: language)
        entry[:ipa] = ipa if ipa
      end
    else
      # LLM fallback: use pronunciation field from API response
      entries.each do |entry|
        entry[:ipa] = entry[:pronunciation] if entry[:pronunciation]
      end
    end
  end

  # Attempt to recover entries from a truncated JSON response.
  # Finds the last complete object (ending with }) and closes the array.
  def salvage_truncated_json(raw)
    # Find the opening bracket
    start = raw.index("[")
    return nil unless start

    # Find the last complete JSON object (ends with "}")
    last_brace = raw.rindex("}")
    return nil unless last_brace && last_brace > start

    json_str = raw[start..last_brace] + "]"
    # Verify it parses
    JSON.parse(json_str)
    json_str
  rescue JSON::ParserError
    nil
  end

  def system_prompt(language, cutoff, filters = {})
    ipa_line = unless Tell::Espeak.supports?(language)
      "\n      - pronunciation: IPA transcription of the lemma (e.g. /word/)"
    end

    filter_lines = build_filter_lines(filters)

    <<~PROMPT
      Given this #{language} text, identify all unique words at CEFR level #{cutoff} or above.
      For each word, provide:
      - word: the word as it appears in text
      - lemma: dictionary form (infinitive for verbs, nominative singular masculine for adjectives, nominative singular for nouns)
      - level: CEFR level (A1/A2/B1/B2/C1/C2)
      - pos: part of speech (noun, verb, adj, adv, etc.)
      - translation: English translation (concise, context-appropriate)
      - definition: brief dictionary-style definition in English (1 sentence)#{ipa_line}

      Return a JSON array. Only include words at #{cutoff} or above.
      Do not include proper nouns, numbers, or punctuation.
      If a word appears in multiple forms, include the most representative occurrence.#{filter_lines}
      Return ONLY the JSON array, no other text.
    PROMPT
  end

  FREQUENCY_PROMPTS = {
    "common" => "Include all words regardless of frequency, including common everyday words.",
    "uncommon" => "Skip the most common high-frequency words. Include moderately uncommon words and above.",
    "rare" => "Only include rare or low-frequency words. Skip common everyday words even if they meet the CEFR level threshold.",
    "literary" => "Only include literary, formal, or elevated-register words. Skip colloquial and everyday vocabulary.",
    "archaic" => "Only include archaic, obsolete, or very rarely used words that most native speakers would not use in modern speech."
  }.freeze

  def build_filter_lines(filters)
    lines = []

    if (prompt = FREQUENCY_PROMPTS[filters[:frequency]])
      lines << prompt
    end

    if filters[:similar]
      langs = filters[:similar]
      lines << "Skip words that a speaker of #{langs} would easily recognize due to shared roots, cognates, or similar form and meaning with the text language."
    end

    lines << filters[:filter] if filters[:filter]

    lines.empty? ? "" : "\n      " + lines.join("\n      ")
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
        line = "- **#{entry[:lemma]}**"
        line += " #{entry[:ipa]}" if entry[:ipa]
        line += " (#{entry[:pos]})"
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

end
