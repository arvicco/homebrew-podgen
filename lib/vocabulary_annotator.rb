# frozen_string_literal: true

require "anthropic"
require "json"
require "set"
require_relative "loggable"
require_relative "retryable"
require_relative "usage_logger"
require "did_you_mean"
require_relative "tell/espeak"
require_relative "tell/hunspell"
require_relative "tell/icu_phonetic"

class VocabularyAnnotator
  include Loggable
  include Retryable
  include UsageLogger

  CEFR_LEVELS = %w[A1 A2 B1 B2 C1 C2].freeze
  MAX_PARTICLE_LENGTH = 3
  PHRASE_BOUNDARY = /(?<=[.!?,;:—–\n])/

  DEFAULT_MODEL = "claude-sonnet-4-6"

  def initialize(api_key, model: nil, logger: nil)
    @logger = logger
    @client = Anthropic::Client.new(api_key: api_key)
    @model = model || ENV.fetch("CLAUDE_VOCAB_MODEL", DEFAULT_MODEL)
  end

  # Returns [marked_body, vocabulary_md]
  # marked_body: transcript with all occurrences of vocab words bolded
  # vocabulary_md: markdown vocabulary section (empty string if no words found)
  def annotate(text, language:, cutoff:, known_lemmas: Set.new, max: nil, filters: {}, include_words: Set.new, target_language: "English", target_languages: nil)
    cutoff = cutoff.upcase
    unless CEFR_LEVELS.include?(cutoff)
      raise ArgumentError, "Invalid CEFR level: #{cutoff}. Must be one of: #{CEFR_LEVELS.join(', ')}"
    end

    target_languages ||= [target_language]
    log("Annotating vocabulary (#{language}, #{cutoff}+ cutoff, definitions in #{target_languages.join(', ')})")

    # Stage 1: Lightweight classification — word/lemma/level/pos only
    entries = classify_words(text, language, cutoff, filters)
    entries = sanitize_script(entries, language)
    entries = dedup_by_lemma(entries)

    # Stage 2: Filter and cap before enrichment to minimize API work
    unless known_lemmas.empty?
      before = entries.length
      entries.reject! { |e| known_lemmas.include?(e[:lemma].to_s.downcase) && !include_words.include?(e[:lemma].to_s.downcase) }
      filtered = before - entries.length
      log("Filtered #{filtered} known words") if filtered > 0
    end

    if entries.empty?
      log("No vocabulary words found at #{cutoff}+ level")
      return [text, ""]
    end

    count_occurrences(text, entries, language)
    priority = filters[:priority] || "balanced"

    # Over-select to leave room for cognate filtering after enrichment
    has_cognate_filter = filters[:similar] && !filters[:similar].empty?
    enrich_cap = max ? (has_cognate_filter ? max * 2 : max) : nil
    if enrich_cap && entries.length > enrich_cap
      included, rest = entries.partition { |e| include_words.include?(e[:lemma].to_s.downcase) }
      sort_entries!(rest, priority, cutoff)
      entries = included + rest.first([enrich_cap - included.length, 0].max)
      log("Pre-enrichment cap: #{entries.length} entries (from #{included.length + rest.length})")
    end

    # Stage 3: Enrich selected entries with translations/definitions
    if target_languages.length == 1
      entries = enrich_entries(entries, language: language, target_language: target_languages.first, filters: filters)
    else
      enrich_multi_language!(entries, language: language, target_languages: target_languages, filters: filters)
    end

    # Stage 4: Post-enrichment filtering
    if has_cognate_filter
      similar_langs = filters[:similar].split(/,\s*/)
      before = entries.length
      entries = filter_cognates(entries, similar_langs, target_languages.first).concat(
        include_words.empty? ? [] : entries.select { |e| include_words.include?(e[:lemma].to_s.downcase) }
      ).uniq { |e| e[:lemma].to_s.downcase }
      filtered_cognates = before - entries.length
      log("Filtered #{filtered_cognates} cognates") if filtered_cognates > 0
    end

    if entries.empty?
      log("No vocabulary words remaining after filtering")
      return [text, ""]
    end

    # Final cap to max
    if max && entries.length > max
      included, rest = entries.partition { |e| include_words.include?(e[:lemma].to_s.downcase) }
      sort_entries!(rest, priority, cutoff)
      entries = included + rest.first([max - included.length, 0].max)
      log("Capped to #{max} entries (priority: #{priority})")
    end

    log("Found #{entries.length} vocabulary words at #{cutoff}+ level")
    add_ipa(entries, language)
    marked_body = mark_words(text, entries, language)
    vocabulary_md = build_vocabulary_section(entries, target_languages)

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
          system: classify_prompt(language, cutoff, filters),
          messages: [
            { role: "user", content: text }
          ]
        )
      end

      log_api_usage("Vocabulary classified", message, elapsed)

      raw = message.content.first.text.strip

      # When response is truncated, go straight to salvage — the regex often
      # matches garbage brackets in preamble text, bypassing recovery.
      if message.stop_reason == "max_tokens"
        json_str = salvage_truncated_json(raw)
        if json_str
          log("Salvaged partial JSON from truncated response")
        else
          log("WARNING: Response truncated at max_tokens and salvage failed")
        end
      else
        # Extract JSON array from response (may be wrapped in ```json ... ```)
        json_str = raw[/\[.*\]/m]
      end

      return [] unless json_str

      entries = JSON.parse(json_str, symbolize_names: true)
      return [] unless entries.is_a?(Array)

      # Validate and normalize entries
      entries.select { |e| valid_entry?(e, cutoff) }
    end
  end

  CYRILLIC_LANGUAGES = Set.new(%w[russian ukrainian bulgarian serbian macedonian belarusian]).freeze

  def sanitize_script(entries, language)
    return entries if CYRILLIC_LANGUAGES.include?(language.to_s.downcase)

    entries.each do |entry|
      %i[word lemma].each do |field|
        next unless entry[field]
        entry[field] = replace_cyrillic(entry[field]) if entry[field].match?(/\p{Cyrillic}/)
      end
    end
    entries
  end

  CYRILLIC_LATIN_MAP = {
    "а" => "a", "б" => "b", "в" => "v", "г" => "g", "д" => "d",
    "е" => "e", "ж" => "zh", "з" => "z", "и" => "i", "й" => "j",
    "к" => "k", "л" => "l", "м" => "m", "н" => "n", "о" => "o",
    "п" => "p", "р" => "r", "с" => "s", "т" => "t", "у" => "u",
    "ф" => "f", "х" => "h", "ц" => "c", "ч" => "ch", "ш" => "sh",
    "щ" => "shch", "ъ" => "", "ы" => "y", "ь" => "", "э" => "e",
    "ю" => "yu", "я" => "ya",
    "А" => "A", "Б" => "B", "В" => "V", "Г" => "G", "Д" => "D",
    "Е" => "E", "Ж" => "Zh", "З" => "Z", "И" => "I", "Й" => "J",
    "К" => "K", "Л" => "L", "М" => "M", "Н" => "N", "О" => "O",
    "П" => "P", "Р" => "R", "С" => "S", "Т" => "T", "У" => "U",
    "Ф" => "F", "Х" => "H", "Ц" => "C", "Ч" => "Ch", "Ш" => "Sh",
    "Щ" => "Shch", "Ъ" => "", "Ы" => "Y", "Ь" => "", "Э" => "E",
    "Ю" => "Yu", "Я" => "Ya"
  }.freeze

  def replace_cyrillic(text)
    if defined?(Tell::IcuPhonetic) && Tell::IcuPhonetic.available?
      result = icu_transliterate(text, "Cyrillic-Latin")
      return result if result
    end
    text.gsub(/\p{Cyrillic}/) { |ch| CYRILLIC_LATIN_MAP[ch] || ch }
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
  # Tries each [ position (there may be brackets in preamble text) paired with
  # each } position backward, until a valid JSON array is found.
  def salvage_truncated_json(raw)
    # Collect all [ positions
    starts = []
    idx = 0
    while (found = raw.index("[", idx))
      starts << found
      idx = found + 1
    end
    return nil if starts.empty?

    # Try each [ (last first — the real JSON array is likely near the end)
    starts.reverse_each do |start|
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
    end
    nil
  end

  # Stage 1 prompt: lightweight classification only (word/lemma/level/pos).
  def classify_prompt(language, cutoff, filters = {})
    filter_lines = build_filter_lines(filters)

    <<~PROMPT
      Given this #{language} text, identify all unique words at CEFR level #{cutoff} or above.
      For each word, provide ONLY these fields:
      - word: the word as it appears in text
      - lemma: dictionary form (infinitive for verbs, positive nominative singular masculine for adjectives — never comparative/superlative, nominative singular for nouns)
      - level: CEFR level (A1/A2/B1/B2/C1/C2)
      - pos: part of speech (noun, verb, adj, adv, etc.)

      Do NOT include translations, definitions, or any other fields.
      Return a JSON array. Only include words at #{cutoff} or above.
      Do not include proper nouns, numbers, or punctuation.
      If a word appears in multiple forms, include the most representative occurrence.
      Merge diminutives with their base word under the base lemma (e.g. peharček → pehar).#{filter_lines}
      Return ONLY the JSON array, no other text.
    PROMPT
  end

  # Stage 3 prompt: enrich selected lemmas with translations and definitions.
  def enrich_prompt(language, target_language, filters = {})
    ipa_line = unless Tell::Espeak.supports?(language)
      "\n      - pronunciation: IPA transcription of the lemma (e.g. /word/)"
    end

    similar_line = if filters[:similar]
      langs = filters[:similar].split(/,\s*/).reject { |l| l.casecmp(target_language).zero? }
      unless langs.empty?
        "\n      - similar_translations: object mapping language name to translation (e.g. {\"Russian\": \"слово\"}). Include: #{langs.join(', ')}"
      end
    end

    <<~PROMPT
      For each #{language} word below, provide:
      - lemma: the word (as given)
      - translation: #{target_language} translation of the word (not inflected forms)
      - definition: brief dictionary-style definition in #{target_language} (1 sentence max)#{ipa_line}#{similar_line}

      Return a JSON array matching the order of input words.
      Return ONLY the JSON array, no other text.
    PROMPT
  end

  PRIORITY_MODES = %w[hardest frequent balanced].freeze

  # Sort entries in place according to the priority mode.
  # - hardest: highest CEFR level first, then frequency, then alpha
  # - frequent: most text occurrences first, then level, then alpha
  # - balanced: prefer words near the cutoff level, then frequency, then alpha
  def sort_entries!(entries, priority, cutoff)
    cutoff_idx = CEFR_LEVELS.index(cutoff)
    case priority
    when "hardest"
      entries.sort_by! { |e| [-CEFR_LEVELS.index(e[:level]), -(e[:frequency] || 0), e[:lemma].to_s.downcase] }
    when "frequent"
      entries.sort_by! { |e| [-(e[:frequency] || 0), -CEFR_LEVELS.index(e[:level]), e[:lemma].to_s.downcase] }
    else # balanced
      entries.sort_by! do |e|
        level_idx = CEFR_LEVELS.index(e[:level])
        distance = (level_idx - cutoff_idx).abs
        [distance, -(e[:frequency] || 0), e[:lemma].to_s.downcase]
      end
    end
  end

  # Stage 3: enrich pre-selected entries with translations/definitions via API.
  def enrich_entries(entries, language:, target_language:, filters:)
    return entries if entries.empty?

    enrichments = call_enrich_api(entries, language: language, target_language: target_language, filters: filters)
    merge_enrichments(entries, enrichments)
  end

  # Stage 3 (multi-language): enrich entries for each target language separately.
  # Stores results in entry[:translations] and entry[:definitions] hashes.
  def enrich_multi_language!(entries, language:, target_languages:, filters:)
    return entries if entries.empty?

    target_languages.each do |tl|
      enrichments = call_enrich_api(entries, language: language, target_language: tl, filters: filters)
      by_lemma = {}
      enrichments.each { |e| by_lemma[e[:lemma].to_s.downcase] = e if e[:lemma] }

      entries.each do |entry|
        enrichment = by_lemma[entry[:lemma].to_s.downcase]
        next unless enrichment

        entry[:translations] ||= {}
        entry[:definitions] ||= {}
        entry[:translations][tl] = enrichment[:translation]
        entry[:definitions][tl] = enrichment[:definition]
        entry[:pronunciation] ||= enrichment[:pronunciation]
        entry[:similar_translations] ||= enrichment[:similar_translations]
      end
    end
    entries
  end

  def call_enrich_api(entries, language:, target_language:, filters:)
    lemmas = entries.map { |e| e[:lemma] }.uniq
    prompt = enrich_prompt(language, target_language, filters)

    with_retries(max: 3, on: [Anthropic::Errors::APIError]) do
      message, elapsed = measure_time do
        @client.messages.create(
          model: @model,
          max_tokens: 16384,
          system: prompt,
          messages: [{ role: "user", content: lemmas.join("\n") }]
        )
      end

      log_api_usage("Vocabulary enriched", message, elapsed)

      raw = message.content.first.text.strip
      json_str = if message.stop_reason == "max_tokens"
        salvage_truncated_json(raw).tap do |r|
          log(r ? "Salvaged partial enrichment" : "WARNING: Enrichment truncated and salvage failed")
        end
      else
        raw[/\[.*\]/m]
      end

      return [] unless json_str

      parsed = JSON.parse(json_str, symbolize_names: true)
      parsed.is_a?(Array) ? parsed : []
    end
  end

  def merge_enrichments(entries, enrichments)
    by_lemma = {}
    enrichments.each { |e| by_lemma[e[:lemma].to_s.downcase] = e if e[:lemma] }

    entries.each do |entry|
      enrichment = by_lemma[entry[:lemma].to_s.downcase]
      next unless enrichment

      entry[:translation] ||= enrichment[:translation]
      entry[:definition] ||= enrichment[:definition]
      entry[:pronunciation] ||= enrichment[:pronunciation]
      entry[:similar_translations] ||= enrichment[:similar_translations]
    end

    entries
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

    # similar-language filtering is handled by code-level filter_cognates, not prompt

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

  # Deterministic cognate filter: compare lemma against translations in similar
  # languages using transliteration + Levenshtein distance.
  def filter_cognates(entries, similar_langs, target_language = "English")
    return entries if similar_langs.empty?

    entries.reject do |entry|
      similar_langs.any? { |lang| cognate_in_language?(entry, lang, target_language) }
    end
  end

  def cognate_in_language?(entry, lang, target_language = "English")
    lemma_ascii = normalize_for_comparison(entry[:lemma].to_s)

    if lang.casecmp(target_language).zero?
      # Multi-lang: check translations hash; single-lang: check translation field
      translation = entry.dig(:translations, lang) || entry[:translation].to_s
      translation.to_s.split(/[,;\/]\s*/).any? do |word|
        word = word.strip.sub(/\Ato /, "")
        cognate?(lemma_ascii, normalize_for_comparison(word))
      end
    else
      # Check translations hash first (multi-lang), then similar_translations
      word = entry.dig(:translations, lang)
      unless word
        translations = entry[:similar_translations]
        return false unless translations.is_a?(Hash)
        word = translations[lang] || translations[lang.to_sym]
      end
      return false unless word

      cognate?(lemma_ascii, normalize_for_comparison(word.to_s))
    end
  end

  def cognate?(a, b)
    return false if a.empty? || b.empty?

    max_len = [a.length, b.length].max
    distance = DidYouMean::Levenshtein.distance(a, b)
    ratio = 1.0 - (distance.to_f / max_len)

    if max_len <= 3
      ratio >= 1.0
    elsif max_len == 4
      ratio >= 0.75
    else
      ratio >= 0.5
    end
  end

  def normalize_for_comparison(text)
    text = text.strip.downcase
    return "" if text.empty?

    if defined?(Tell::IcuPhonetic) && Tell::IcuPhonetic.available?
      if text.match?(/\p{Cyrillic}/)
        result = icu_transliterate(text, "Cyrillic-Latin; Latin-ASCII")
        return result if result
      end
      result = icu_transliterate(text, "Latin-ASCII")
      return result if result
    end

    text.unicode_normalize(:nfkd).gsub(/\p{M}/, "").tr("đ", "d").tr("ł", "l")
  end

  def icu_transliterate(text, tid)
    require "ffi-icu"
    t = ICU::Transliteration::Transliterator.new(tid)
    result = t.transliterate(text).downcase
    result.empty? ? nil : result
  rescue LoadError, ICU::Error
    nil
  end

  def all_forms_for(entry)
    ((entry[:words] || [entry[:word]]) + [entry[:lemma]]).compact.uniq(&:downcase)
  end

  # Split forms into [head_forms, particle_forms] for multi-word lemmas.
  # Particles are extracted from the lemma (e.g., "se" from "izviti se"),
  # regardless of whether Claude returned them in the words array.
  # Single-word lemmas return all forms as head, no particles.
  def partition_forms(entry)
    forms = all_forms_for(entry)
    lemma = entry[:lemma].to_s
    return [forms, []] unless lemma.include?(" ")

    particle_parts = lemma.split.select { |part| part.length <= MAX_PARTICLE_LENGTH }.map(&:downcase)
    return [forms, []] if particle_parts.empty?

    particle_set = Set.new(particle_parts)
    head_forms = forms.reject { |f| particle_set.include?(f.downcase) }
    [head_forms, particle_parts]
  end

  def count_occurrences(text, entries, language)
    entries.each do |entry|
      head_forms, particles = partition_forms(entry)
      if language && Tell::Hunspell.supports?(language)
        expanded = Tell::Hunspell.expand(entry[:lemma], lang: language)
        if expanded.any?
          particle_set = Set.new(particles.map(&:downcase))
          expanded = expanded.reject { |f| particle_set.include?(f.downcase) }
          entry[:_expanded] = expanded
          head_forms = (head_forms + expanded).uniq(&:downcase)
        end
      end
      entry[:frequency] = head_forms.sum { |f| text.scan(/\b#{Regexp.escape(f)}\b/i).length }
    end
  end

  def mark_words(text, entries, language = nil)
    marked = text.dup

    # Collect per-entry data: head/particle split + hunspell expansion
    entry_data = entries.map do |entry|
      head_forms, particle_forms = partition_forms(entry)

      expanded = entry.delete(:_expanded)
      if expanded.nil? && language && Tell::Hunspell.supports?(language)
        expanded = Tell::Hunspell.expand(entry[:lemma], lang: language)
      end

      if expanded&.any?
        particle_set = Set.new(particle_forms.map(&:downcase))
        expanded = expanded.reject { |f| particle_set.include?(f.downcase) }
        head_forms = (head_forms + expanded).uniq(&:downcase)
        existing = (entry[:words] || [entry[:word]]).map(&:downcase)
        expanded.each do |form|
          if !existing.include?(form.downcase) && text.match?(/\b#{Regexp.escape(form)}\b/i)
            entry[:words] ||= [entry[:word]]
            entry[:words] << form
          end
        end
      end

      { entry: entry, head_forms: head_forms, particle_forms: particle_forms }
    end

    # Pass 1: bold all head forms from all entries
    entry_data.each do |data|
      data[:head_forms].each do |form|
        pattern = /(?<!\*)\b(#{Regexp.escape(form)})\b(?!\*)/i
        marked.gsub!(pattern, '**\1**')
      end
    end

    # Pass 2: bold particles only in phrases containing a bolded head form from the same entry
    entry_data.each do |data|
      next if data[:particle_forms].empty?

      bolded_head_re = Regexp.union(data[:head_forms].map { |h| /\*\*#{Regexp.escape(h)}\*\*/i })

      data[:particle_forms].each do |particle|
        particle_re = /(?<!\*)\b(#{Regexp.escape(particle)})\b(?!\*)/i
        phrases = marked.split(PHRASE_BOUNDARY)
        phrases.each_index do |i|
          next unless phrases[i].match?(bolded_head_re)
          phrases[i] = phrases[i].sub(particle_re, '**\1**')
        end
        marked = phrases.join
      end
    end

    marked
  end

  def build_vocabulary_section(entries, target_languages = nil)
    sorted = entries.sort_by { |e| e[:lemma].to_s.downcase }
    multi = target_languages && target_languages.length > 1

    heading = multi ? "## Vocabulary (#{target_languages.join(', ')})" : "## Vocabulary"
    lines = [heading, ""]

    sorted.each do |entry|
      line = "- **#{entry[:lemma]}**"
      line += " #{entry[:ipa]}" if entry[:ipa]
      line += " (#{entry[:level]} #{entry[:pos]})"
      # Show word forms that differ from lemma, excluding particles
      _head, particle_forms = partition_forms(entry)
      particle_set = Set.new(particle_forms.map(&:downcase))
      diff_forms = (entry[:words] || [entry[:word]])
        .reject { |w| w.downcase == entry[:lemma].downcase }
        .reject { |w| particle_set.include?(w.downcase) }
      line += " *#{diff_forms.join(', ')}*" unless diff_forms.empty?

      if multi
        lines << line
        target_languages.each do |tl|
          translation = entry.dig(:translations, tl)
          definition = entry.dig(:definitions, tl)
          next unless translation || definition
          def_line = "  - #{translation}"
          def_line += ". #{definition}" if definition
          lines << def_line
        end
      else
        line += " — #{entry[:translation]}" if entry[:translation]
        line += ". #{entry[:definition]}" if entry[:definition]
        lines << line
      end
    end

    lines.join("\n").strip
  end

end
