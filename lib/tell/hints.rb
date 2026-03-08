# frozen_string_literal: true

module Tell
  module Hints
    # Single-char flags for translation style hints.
    # Appended as suffix: "hello /pm" → polite + male speaker.
    FLAGS = {
      "p" => :polite,
      "c" => :casual,
      "v" => :very_formal,
      "h" => :humble,
      "m" => :male,
      "f" => :female,
      "n" => :neuter
    }.freeze

    FORMALITY = %i[polite casual very_formal humble].freeze
    GENDER    = %i[male female neuter].freeze

    Result = Struct.new(:text, :formality, :gender, keyword_init: true) do
      def hints?
        !formality.nil? || !gender.nil?
      end
    end

    # Match /flags at end of string, preceded by a word char, whitespace,
    # punctuation, or start-of-string. All chars after / must be valid flag letters.
    HINT_RE = %r{(?:\A|(?<=[\w\p{L}\p{M}\s\p{P}]))/([pcvhmfn]+)\z}

    # Parse hint suffix from text. Returns Result with cleaned text + hints.
    def self.parse(text)
      match = text.match(HINT_RE)
      # Reject if the /flags look like a URL path (e.g. http://example.com/pm)
      if match
        before = text[0...match.begin(0)]
        match = nil if before.include?("://")
      end
      unless match
        return Result.new(text: text, formality: nil, gender: nil)
      end

      flags = match[1].chars.filter_map { |c| FLAGS[c] }
      formality = flags.find { |f| FORMALITY.include?(f) }
      gender    = flags.find { |f| GENDER.include?(f) }

      Result.new(
        text: text[0...match.begin(0)].rstrip,
        formality: formality,
        gender: gender
      )
    end

    # Convert hints to a natural language instruction for LLM translators.
    # Returns nil if no hints are set.
    def self.to_instruction(hints)
      return nil unless hints&.hints?

      parts = []
      case hints.formality
      when :polite
        parts << "polite/formal register (use formal 'you' where applicable — e.g. vikanje, Sie, vous, usted)"
      when :casual
        parts << "casual/informal register (use informal 'you' where applicable — e.g. tikanje, du, tu, tú)"
      when :very_formal
        parts << "very formal/honorific register (use the highest formality level — e.g. Japanese sonkeigo, Korean 합쇼체)"
      when :humble
        parts << "humble/deferential register (use humble/lowering forms — e.g. Japanese kenjōgo)"
      end

      case hints.gender
      when :male   then parts << "the speaker is male — use masculine grammatical gender where applicable (participles, adjectives, pronouns) — do NOT invent gendered forms that don't exist in the language"
      when :female then parts << "the speaker is female — use feminine grammatical gender where applicable (participles, adjectives, pronouns) — do NOT invent gendered forms that don't exist in the language"
      when :neuter then parts << "use neuter grammatical gender for all gendered forms (verb participles, adjectives, pronouns — e.g. Slovenian -lo/-o endings, NOT masculine/feminine slashes)"
      end

      parts.empty? ? nil : parts.join("; ")
    end

    # Map formality hint to DeepL formality parameter.
    # Returns nil for unmappable hints (humble) or no hint.
    def self.deepl_formality(hints)
      return nil unless hints&.formality

      case hints.formality
      when :polite, :very_formal then "prefer_more"
      when :casual               then "prefer_less"
      end
    end
  end
end
