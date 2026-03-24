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
    entries = dedup_by_lemma(entries)
    entries = dedup_by_family(entries)
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

  # Split threshold: texts longer than this (in chars) get chunked to avoid
  # hitting max_tokens on the response. ~4000 chars ≈ ~1000 tokens input.
  CHUNK_THRESHOLD = 4000

  def classify_words(text, language, cutoff, filters = {})
    if text.length > CHUNK_THRESHOLD
      return classify_chunked(text, language, cutoff, filters)
    end

    classify_single(text, language, cutoff, filters)
  end

  def classify_chunked(text, language, cutoff, filters)
    chunks = split_into_chunks(text)
    return classify_single(text, language, cutoff, filters) if chunks.length < 2

    log("Splitting into #{chunks.length} chunks for classification")
    threads = chunks.map do |chunk|
      Thread.new { classify_single(chunk, language, cutoff, filters) }
    end
    threads.flat_map(&:value)
  end

  def split_into_chunks(text)
    paragraphs = text.split(/\n{2,}/)
    return [text] if paragraphs.length < 2

    mid = paragraphs.length / 2
    [
      paragraphs[0...mid].join("\n\n"),
      paragraphs[mid..].join("\n\n")
    ]
  end

  def classify_single(text, language, cutoff, filters = {})
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
        if json_str
          log("Salvaged partial JSON from truncated response")
        else
          log("WARNING: Response truncated at max_tokens and salvage failed")
        end
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
  # Iterates backward through } positions to find the last one that produces
  # valid JSON (skipping } chars that appear inside string values).
  def salvage_truncated_json(raw)
    start = raw.index("[")
    return nil unless start

    pos = raw.length
    while pos > start
      pos = raw.rindex("}", pos - 1)
      break unless pos && pos > start

      begin
        candidate = raw[start..pos] + "]"
        parsed = JSON.parse(candidate)
        return candidate if parsed.is_a?(Array) && !parsed.empty?
      rescue JSON::ParserError
        next
      end
    end
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
      - translation: English translation of the LEMMA (not the inflected form)
      - definition: brief dictionary-style definition of the LEMMA in English (1 sentence)
      - family: the root word of the word family this lemma belongs to (the simplest/most fundamental lemma that related words derive from). Words sharing the same root AND similar meaning should have the same family tag. Words with the same root but unrelated meanings get different family tags#{ipa_line}

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
      lines << "Skip words that a speaker of #{langs} would easily recognize. Compare phonetically and etymologically across writing systems (e.g. Latin/Cyrillic/etc.) — words with the same root and meaning in #{langs} must be excluded even if the scripts differ. Think about how each word sounds, not how it looks (e.g. 'klokotanje'='клокотание', 'pritajiti se'='притаиться')."
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

  # Merge entries with the same lemma, collecting all distinct word forms.
  # Keeps the first entry's metadata (level, pos, translation, definition).
  def dedup_by_lemma(entries)
    by_lemma = {}
    entries.each do |entry|
      key = entry[:lemma].to_s.downcase
      if by_lemma[key]
        existing = by_lemma[key]
        existing[:words] << entry[:word] unless existing[:words].any? { |w| w.downcase == entry[:word].downcase }
      else
        by_lemma[key] = entry.merge(words: [entry[:word]])
      end
    end
    by_lemma.values
  end

  # Merge entries sharing the same word family (same root + similar meaning).
  # Prefers the entry whose lemma matches the family tag (the root word).
  # Entries without a family field pass through unchanged.
  def dedup_by_family(entries)
    with_family, without_family = entries.partition { |e| e[:family] }
    by_family = {}

    with_family.each do |entry|
      key = entry[:family].to_s.downcase
      if by_family[key]
        existing = by_family[key]
        # Merge word forms
        (entry[:words] || [entry[:word]]).each do |w|
          existing[:words] << w unless existing[:words].any? { |ew| ew.downcase == w.downcase }
        end
        # If this entry's lemma matches the family tag, prefer its metadata
        if entry[:lemma].to_s.downcase == key && existing[:lemma].to_s.downcase != key
          old_words = existing[:words]
          by_family[key] = entry.merge(words: old_words)
        end
      else
        by_family[key] = entry.merge(words: entry[:words] || [entry[:word]])
      end
    end

    by_family.values + without_family
  end

  def mark_words(text, entries)
    marked = text.dup

    entries.each do |entry|
      # Mark all occurrences of all known forms + the lemma
      forms = ((entry[:words] || [entry[:word]]) + [entry[:lemma]]).compact.uniq(&:downcase)
      forms.each do |form|
        pattern = /(?<!\*)\b(#{Regexp.escape(form)})\b(?!\*)/i
        marked.gsub!(pattern, '**\1**')
      end
    end

    marked
  end

  def build_vocabulary_section(entries)
    sorted = entries.sort_by { |e| e[:lemma].to_s.downcase }

    lines = ["## Vocabulary", ""]
    sorted.each do |entry|
      line = "- **#{entry[:lemma]}**"
      line += " #{entry[:ipa]}" if entry[:ipa]
      line += " (#{entry[:level]} #{entry[:pos]})"
      # Show word forms that differ from lemma
      diff_forms = (entry[:words] || [entry[:word]]).reject { |w| w.downcase == entry[:lemma].downcase }
      line += " *#{diff_forms.join(', ')}*" unless diff_forms.empty?
      line += " — #{entry[:translation]}" if entry[:translation]
      line += ". #{entry[:definition]}" if entry[:definition]
      lines << line
    end

    lines.join("\n").strip
  end

end
