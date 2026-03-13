# frozen_string_literal: true

require_relative "../language_names"

module Tell
  class Glosser
    # --- Phonetic systems per language ---
    # Ordered hash: first key = default system for that language.
    # Config: label (UI), standalone (prompt), bracket (gloss prompt), separator (word delimiter).
    PHONETIC_SYSTEMS = begin
      ipa = ->(standalone: nil, bracket: nil) {
        {
          label: "IPA",
          standalone: standalone || "Provide IPA transcription enclosed in slashes. Output ONLY the IPA on a single line, no headers or formatting.",
          bracket: bracket || "Phonetic: IPA transcription in brackets",
          separator: " "
        }.freeze
      }

      cyrillic = {
        "scholarly" => {
          label: "Scholarly",
          standalone: "Romanize using scholarly transliteration. Output ONLY the romanization.",
          bracket: "Phonetic: scholarly romanization",
          separator: " "
        }.freeze,
        "simple" => {
          label: "Simple",
          standalone: "Romanize using simplified romanization (no diacritics). Output ONLY the romanized text on a single line, no headers or formatting.",
          bracket: "Phonetic: simplified romanization (no diacritics)",
          separator: " "
        }.freeze,
        "ipa" => ipa.call
      }.freeze

      indic = {
        "iast" => {
          label: "IAST",
          standalone: "Convert to IAST romanization. Output ONLY the romanization.",
          bracket: "Phonetic: IAST romanization",
          separator: " "
        }.freeze,
        "ipa" => ipa.call
      }.freeze

      hebrew = {
        "standard" => {
          label: "Standard",
          standalone: "Romanize using standard transliteration. Output ONLY the romanization.",
          bracket: "Phonetic: standard transliteration",
          separator: " "
        }.freeze,
        "ipa" => ipa.call
      }.freeze

      {
        "ja" => {
          "hiragana" => {
            label: "Hiragana",
            standalone: "Convert to hiragana reading. Separate words with middle dots (・). Spell particles phonetically: は→わ, へ→え. Output ONLY the hiragana.",
            bracket: "Phonetic: hiragana reading in brackets, e.g. [おげんき]",
            separator: "・"
          }.freeze,
          "hepburn" => {
            label: "Hepburn",
            standalone: "Romanize using modified Hepburn romanization. Separate words with spaces. Output ONLY the romanization.",
            bracket: "Phonetic: Hepburn romanization in brackets, e.g. [ogenki]",
            separator: " "
          }.freeze,
          "kunrei" => {
            label: "Kunrei",
            standalone: "Romanize using Kunrei-shiki romanization. Separate words with spaces. Output ONLY the romanization.",
            bracket: "Phonetic: Kunrei-shiki romanization in brackets, e.g. [ogenki]",
            separator: " "
          }.freeze,
          "ipa" => ipa.call
        }.freeze,
        "zh" => {
          "pinyin" => {
            label: "Pinyin",
            standalone: "Convert to pinyin with tone marks (e.g. nǐ hǎo). Output ONLY the pinyin.",
            bracket: "Phonetic: pinyin with tone marks, e.g. [nǐ hǎo]",
            separator: " "
          }.freeze,
          "zhuyin" => {
            label: "Zhuyin",
            standalone: "Convert to Zhuyin/Bopomofo (e.g. ㄋㄧˇ ㄏㄠˇ). Output ONLY the Zhuyin.",
            bracket: "Phonetic: Zhuyin/Bopomofo in brackets, e.g. [ㄋㄧˇ ㄏㄠˇ]",
            separator: " "
          }.freeze,
          "ipa" => ipa.call
        }.freeze,
        "ko" => {
          "rr" => {
            label: "Revised",
            standalone: "Convert to Revised Romanization (e.g. annyeonghaseyo). Output ONLY the romanization.",
            bracket: "Phonetic: Revised Romanization, e.g. [annyeong]",
            separator: " "
          }.freeze,
          "mr" => {
            label: "McCune",
            standalone: "Convert to McCune-Reischauer romanization (e.g. annyŏnghaseyo). Output ONLY the romanization.",
            bracket: "Phonetic: McCune-Reischauer romanization in brackets, e.g. [annyŏng]",
            separator: " "
          }.freeze,
          "ipa" => ipa.call
        }.freeze,
        "ar" => {
          "romanization" => {
            label: "Roman.",
            standalone: "Romanize with standard diacritics. Output ONLY the romanization.",
            bracket: "Phonetic: romanization with diacritics",
            separator: " "
          }.freeze,
          "ipa" => ipa.call
        }.freeze,
        "th" => {
          "rtgs" => {
            label: "RTGS",
            standalone: "Convert to RTGS romanization. Output ONLY the romanization.",
            bracket: "Phonetic: RTGS romanization",
            separator: " "
          }.freeze,
          "ipa" => ipa.call
        }.freeze,
        "ka" => {
          "national" => {
            label: "National",
            standalone: "Romanize using national romanization. Output ONLY the romanization.",
            bracket: "Phonetic: national romanization",
            separator: " "
          }.freeze,
          "ipa" => ipa.call
        }.freeze,
        "el" => {
          "elot" => {
            label: "ELOT",
            standalone: "Romanize using UN/ELOT romanization. Output ONLY the romanization.",
            bracket: "Phonetic: UN/ELOT romanization",
            separator: " "
          }.freeze,
          "ipa" => ipa.call
        }.freeze,
        "ru" => cyrillic, "uk" => cyrillic, "bg" => cyrillic,
        "sr" => cyrillic, "mk" => cyrillic, "be" => cyrillic,
        "hi" => indic, "sa" => indic, "ne" => indic, "mr" => indic,
        "he" => hebrew, "yi" => hebrew,
        "_default" => {
          "ipa" => {
            label: "IPA",
            standalone: "Provide IPA transcription enclosed in slashes (e.g. /example/). Output ONLY the IPA on a single line, no headers or formatting.",
            bracket: "Phonetic: IPA transcription, e.g. [ˈhɛloʊ]",
            separator: " "
          }.freeze,
          "simple" => {
            label: "Simple",
            standalone: "Provide simplified phonetic spelling using common English letter combinations (e.g. nyeh for nje). Output ONLY the phonetic text on a single line, no headers or formatting.",
            bracket: "Phonetic: simplified phonetic spelling in brackets",
            separator: " "
          }.freeze
        }.freeze
      }.freeze
    end

    # Available phonetic systems for a language.
    def self.systems_for(lang)
      PHONETIC_SYSTEMS[lang] || PHONETIC_SYSTEMS["_default"]
    end

    # Default phonetic system key for a language.
    def self.default_system(lang)
      systems_for(lang).keys.first
    end

    # Look up config for a specific system (or default).
    def self.system_config(lang, system: nil)
      systems = systems_for(lang)
      if system
        systems[system] || systems.values.first
      else
        systems.values.first
      end
    end

    # Run a block across one or more models, collecting results.
    # Single model: call directly (no thread overhead).
    # Multi model: parallel threads, filter errors, raise only if ALL fail.
    # Returns {model_id => result}.
    def self.multi_model(models)
      models = Array(models)
      if models.size == 1
        { models.first => yield(models.first) }
      else
        results = {}
        errors = {}
        mu = Mutex.new
        threads = models.map do |mid|
          Thread.new(mid) do |m|
            r = yield(m)
            mu.synchronize { results[m] = r }
          rescue => e
            mu.synchronize { errors[m] = e }
          end
        end
        threads.each(&:join)
        raise errors.values.first if results.empty?
        results
      end
    end

    def initialize(api_key, model: "claude-opus-4-6")
      require "anthropic"
      @client = Anthropic::Client.new(api_key: api_key, timeout: 15, max_retries: 1)
      @model = model
    end

    def gloss(text, from:, to:, system: nil)
      ask(build_gloss_prompt(text, from: from, to: to, translate: false, phonetic: false))
    end

    def gloss_translate(text, from:, to:, system: nil)
      ask(build_gloss_prompt(text, from: from, to: to, translate: true, phonetic: false))
    end

    def gloss_phonetic(text, from:, to:, phonetic_ref: nil, system: nil)
      ask(build_gloss_prompt(text, from: from, to: to, translate: false, phonetic: true, phonetic_ref: phonetic_ref, system: system))
    end

    def gloss_translate_phonetic(text, from:, to:, phonetic_ref: nil, system: nil)
      ask(build_gloss_prompt(text, from: from, to: to, translate: true, phonetic: true, phonetic_ref: phonetic_ref, system: system))
    end

    # Split standalone phonetic output into per-word readings.
    def self.split_phonetic(phonetic_text, lang:, system: nil)
      separator = system_config(lang, system: system)[:separator]
      text = phonetic_text.strip
      if separator == "・"
        text.split(/\s*・\s*/)
      else
        text.delete_prefix("/").delete_suffix("/").strip.split(/\s+/)
      end
    end

    # Mechanically merge per-word phonetic readings into a gloss string.
    # Returns merged string if word counts align 1:1, nil otherwise.
    GLOSS_WORD_RE = /(?:\*\S+?\*)?\S+?\([^)]+\)\S*/

    def self.merge_phonetic(gloss, phonetic_text, lang:, system: nil)
      readings = split_phonetic(phonetic_text, lang: lang, system: system)
      return nil if readings.empty?

      word_count = gloss.scan(GLOSS_WORD_RE).size
      return nil unless word_count == readings.size

      idx = 0
      gloss.gsub(GLOSS_WORD_RE) do |match|
        reading = readings[idx]
        idx += 1
        match.sub("(", "[#{reading}](")
      end
    end

    # Replace existing [bracket] readings in a gloss using standalone phonetic readings.
    # Unlike merge_phonetic (which inserts new brackets and returns nil on mismatch),
    # this corrects EXISTING bracket contents and always returns a string.
    def self.correct_readings(gloss, phonetic_text, lang:, system: nil)
      readings = split_phonetic(phonetic_text, lang: lang, system: system)
      return gloss if readings.empty?

      words = gloss.scan(GLOSS_WORD_RE)
      return gloss unless words.size == readings.size

      idx = 0
      gloss.gsub(GLOSS_WORD_RE) do |match|
        reading = readings[idx]
        idx += 1
        if match.include?("[")
          match.sub(/\[[^\]]+\]/, "[#{reading}]")
        else
          match
        end
      end
    end

    def phonetic(text, lang:, system: nil)
      lang_name = LANGUAGE_NAMES.fetch(lang, lang)
      instruction = phonetic_standalone_instruction(lang, system: system)

      ask(<<~PROMPT, max_tokens: 1024)
        #{instruction}

        #{lang_name} text: #{text}
      PROMPT
    end

    def reconcile(glosses, text, from:, to:, mode:, system: nil)
      from_name = LANGUAGE_NAMES.fetch(from, from)
      to_name = LANGUAGE_NAMES.fetch(to, to)

      parts = glosses.map { |model, gloss| "=== #{model} ===\n#{gloss}" }.join("\n\n")

      translate = mode == :gloss_translate || mode == :gloss_translate_phonetic
      has_phonetic = mode == :gloss_phonetic || mode == :gloss_translate_phonetic

      format_instruction = if translate
        "word(grammar)translation — translation immediately after closing paren, no space. " \
        "Omit translation when identical to the original word."
      else
        "word(grammar) — no spaces around parentheses."
      end

      ph_instruction = if has_phonetic
        " Include phonetic reading in square brackets between word and grammar: word[reading](grammar). " \
        "Omit [reading] when the word is already readable (identical reading, Latin-script words, proper names). #{phonetic_bracket_instruction(from, system: system)}"
      else
        ""
      end

      ask(<<~PROMPT)
        You are a linguistic gloss reconciliation expert. Compare these #{glosses.size} glosses of the same #{from_name} text word by word and produce the best consensus gloss.

        Original text: #{text}

        #{parts}

        Rules:
        - For grammar labels: pick the most accurate morphological analysis.
        - For agrammatical markings (*wrong*correction): keep ONLY if multiple models agree on both the error AND the correction. If models disagree or only one marks it, output the word unmarked with its grammar labels.
        - For translations (if present): pick the most context-appropriate #{to_name} translation.
        - Output format: #{format_instruction}#{ph_instruction}
        - Keep punctuation in place without glossing it.
        - Output ONLY the reconciled gloss line. One line, words separated by spaces.
      PROMPT
    end

    def reconcile_phonetic(phonetics, text, lang:, system: nil)
      lang_name = LANGUAGE_NAMES.fetch(lang, lang)
      sys_cfg = self.class.system_config(lang, system: system)
      parts = phonetics.map { |model, ph| "=== #{model} ===\n#{ph}" }.join("\n\n")

      ask(<<~PROMPT)
        You are a phonetic transcription reconciliation expert. Compare these #{phonetics.size} transcriptions of the same #{lang_name} text and produce the best consensus.

        Original text: #{text}

        #{parts}

        Rules:
        - #{sys_cfg[:standalone]}
        - Pick the most accurate transcription for each word.
        - Output ONLY the reconciled transcription on a single line.
      PROMPT
    end

    private

    def ask(prompt, max_tokens: 4096)
      message = @client.messages.create(
        model: @model,
        max_tokens: max_tokens,
        messages: [{ role: "user", content: prompt }]
      )
      message.content.first.text.strip
    end

    def build_gloss_prompt(text, from:, to:, translate:, phonetic:, phonetic_ref: nil, system: nil)
      from_name = LANGUAGE_NAMES.fetch(from, from)
      to_name = LANGUAGE_NAMES.fetch(to, to)

      parts = []

      # Opening instruction
      parts << opening_instruction(from_name, to_name, translate: translate, phonetic: phonetic)

      # Format instruction
      parts << format_instruction(from_name, to_name, translate: translate, phonetic: phonetic)

      # Phonetic omission rule (non-Latin scripts only)
      parts << phonetic_omission_instruction(from) if phonetic

      # Translation-specific rules
      parts << translation_rules(from_name, to_name) if translate

      # Phonetic bracket instruction
      parts << phonetic_bracket_instruction(from, system: system) if phonetic

      # Pre-computed phonetic reference — use these readings for [brackets]
      if phonetic && phonetic_ref
        parts << "IMPORTANT: Use this pre-computed phonetic transcription as reference for [bracket] readings. " \
                 "Split it per word and use the same readings: #{phonetic_ref}"
      end

      # Common rules
      parts << "Keep punctuation in place but do not gloss it — leave commas, periods, question marks, etc. as-is without parentheses."
      parts << "Omit translation when it would be identical to the original word (proper names, loanwords, cognates)." if translate

      # Example (only for translate modes without phonetic)
      if translate && !phonetic
        parts << ""
        parts << "Example (#{from_name} → English): Pirina(n.prop.f.N.sg) svet(n.m.N.sg)world gremo(v.1p.pres.pl)we-go ti(pron.2p.D.sg)to-you te(pron.2p.A.sg)you sva(v.aux.1p.past.du)we-two-were rekli(v.perf.past.m.pl)said"
      end

      parts << ""
      parts << GRAMMAR_ABBREVIATIONS
      parts << ""
      parts << "Output ONLY the glossed line. Keep original word order. One line, words separated by spaces."
      parts << ""
      parts << text

      parts.reject { |p| p.nil? || (p.is_a?(String) && p.empty? && parts[parts.index(p) - 1]&.empty?) }
           .join("\n")
    end

    def opening_instruction(from_name, to_name, translate:, phonetic:)
      if translate && phonetic
        "Provide an interlinear gloss with #{to_name} translations and phonetic readings of the following #{from_name} text."
      elsif translate
        "Provide an interlinear gloss with #{to_name} translations of the following #{from_name} text."
      elsif phonetic
        "Provide an interlinear gloss with phonetic readings of the following #{from_name} text."
      else
        "Provide an interlinear gloss of the following #{from_name} text."
      end
    end

    def format_instruction(from_name, to_name, translate:, phonetic:)
      if translate && phonetic
        "For each word output: word[phonetic](grammar)translation — phonetic in brackets between word and grammar, translation after paren."
      elsif translate
        "For each word output: word(grammar)translation — translation immediately after closing paren, no space."
      elsif phonetic
        "For each word output: word[phonetic](abbr) — phonetic reading in square brackets between word and grammar."
      else
        "For each word output: word(abbr) — no spaces around parentheses."
      end
    end

    def translation_rules(from_name, to_name)
      <<~RULES.chomp
        The translation must capture the FULL meaning of the word. Use hyphens for multi-word translations (standard interlinear convention).
        Choose the translation that fits the sentence context, not just the dictionary default — e.g. "criticized" not "offended" if the context is about blaming someone.
        Each translation must be in the INFLECTED form — not the dictionary form. If #{to_name} is inflected, decline/conjugate the translation word accordingly (e.g. locative source → locative translation, not nominative). For non-inflected target languages, show case via prepositions (e.g. dative "to-you", genitive "of-him").
        Do NOT translate different case forms identically.
        IMPORTANT — gender agreement: the grammar labels describe #{from_name} gender, but translations must agree with the #{to_name} noun's own gender. When a noun changes gender across languages, ALL modifiers (adjectives, pronouns, participles) must use the #{to_name} gender. E.g. #{from_name} "žoga"(f) = #{to_name} "мяч"(m): translate adjectives in masculine, not feminine — "старым мячом" not "старой мячой".
      RULES
    end

    NON_LATIN_LANGS = %w[ja zh ko ar th hi sa ne mr ru uk bg sr mk be ka el he yi].freeze

    def phonetic_bracket_instruction(lang, system: nil)
      self.class.system_config(lang, system: system)[:bracket]
    end

    def phonetic_omission_instruction(lang)
      if NON_LATIN_LANGS.include?(lang)
        "Omit [phonetic] when the word is already readable: identical reading (e.g. hiragana-only Japanese), Latin-script words (proper names, technical terms, loanwords like \"SQLite\"), or words that need no transliteration."
      end
    end

    def phonetic_standalone_instruction(lang, system: nil)
      self.class.system_config(lang, system: system)[:standalone]
    end

    GRAMMAR_ABBREVIATIONS = <<~ABBR.freeze
      Abbreviations (dot-separated inside parens, STRICT order — always use this slot order, skip inapplicable slots):
      1. POS: n v adj adv pr conj pron det part num interj
      2. Subtype: aux refl neg
      3. Aspect: perf imperf
      4. Person: 1p 2p 3p
      5. Tense/mood: pres past fut inf ind imp cond
      6. Gender: m f n
      7. Case: N G D A L I V
      8. Number: sg pl du
      9. Degree: comp sup dim
      10. Definiteness: def indef
      IMPORTANT: ALWAYS include number (sg/pl/du) on nouns, verbs, adjectives, and pronouns. Never omit it.
      IMPORTANT: Analyze each word's grammar in the SOURCE language, not based on how its translation functions. E.g. Slovenian "prosim" is v.1p.pres.sg (from prositi=to ask), NOT adv just because English "please" is an adverb.
      Proper names in inflected languages decline as nouns — gloss as n.prop, NOT as adjectives. E.g. Pirini(n.prop.f.D.sg) not Pirini(adj.f.D.sg).
      Agrammatical forms: if a word has a clear grammatical error (wrong declension/conjugation ending, obvious misspelling), mark as *original*correction(grammar). The correction MUST differ from the original — if you cannot provide a different corrected form, do NOT mark it. Only mark when you are certain the correction is valid. When unsure, gloss the word as-is without marking.
    ABBR
  end
end
