# frozen_string_literal: true

require_relative "../language_names"

module Tell
  class Glosser
    def initialize(api_key, model: "claude-opus-4-6")
      require "anthropic"
      @client = Anthropic::Client.new(api_key: api_key, timeout: 15, max_retries: 1)
      @model = model
    end

    def gloss(text, from:, to:)
      from_name = LANGUAGE_NAMES.fetch(from, from)
      to_name = LANGUAGE_NAMES.fetch(to, to)

      message = @client.messages.create(
          model: @model,
          max_tokens: 4096,
          messages: [
            {
              role: "user",
              content: <<~PROMPT
                Provide an interlinear gloss of the following #{from_name} text.
                For each word output: word(abbr) — no spaces around parentheses.
                Keep punctuation in place but do not gloss it — leave commas, periods, question marks, etc. as-is without parentheses.
                Omit translation when it would be identical to the original word (proper names, loanwords, cognates).

                #{GRAMMAR_ABBREVIATIONS}

                Output ONLY the glossed line. Keep original word order. One line, words separated by spaces.

                #{text}
              PROMPT
            }
          ]
        )

        message.content.first.text.strip
    end

    def gloss_translate(text, from:, to:)
      from_name = LANGUAGE_NAMES.fetch(from, from)
      to_name = LANGUAGE_NAMES.fetch(to, to)

      message = @client.messages.create(
          model: @model,
          max_tokens: 4096,
          messages: [
            {
              role: "user",
              content: <<~PROMPT
                Provide an interlinear gloss with #{to_name} translations of the following #{from_name} text.
                For each word output: word(grammar)translation — translation immediately after closing paren, no space.
                The translation must capture the FULL meaning of the word. Use hyphens for multi-word translations (standard interlinear convention).
                Choose the translation that fits the sentence context, not just the dictionary default — e.g. "criticized" not "offended" if the context is about blaming someone.
                Translations must reflect grammatical case — e.g. dative "to-you", genitive "of-him", instrumental "with-us". Do NOT translate different case forms identically.
                Keep punctuation in place but do not gloss it — leave commas, periods, question marks, etc. as-is without parentheses.
                Omit translation when it would be identical to the original word (proper names, loanwords, cognates).

                Example: Pirina(n.prop.f.N.sg) svet(n.m.N.sg)world gremo(v.1p.pres.pl)we-go ti(pron.2p.D.sg)to-you te(pron.2p.A.sg)you sva(v.aux.1p.past.du)we-two-were rekli(v.perf.past.m.pl)said

                #{GRAMMAR_ABBREVIATIONS}

                Output ONLY the glossed line. Keep original word order. One line, words separated by spaces.

                #{text}
              PROMPT
            }
          ]
        )

        message.content.first.text.strip
    end

    def reconcile(glosses, text, from:, to:, mode:)
      from_name = LANGUAGE_NAMES.fetch(from, from)
      to_name = LANGUAGE_NAMES.fetch(to, to)

      parts = glosses.map { |model, gloss| "=== #{model} ===\n#{gloss}" }.join("\n\n")

      format_instruction = if mode == :gloss_translate
        "word(grammar)translation — translation immediately after closing paren, no space. " \
        "Omit translation when identical to the original word."
      else
        "word(grammar) — no spaces around parentheses."
      end

      prompt = <<~PROMPT
        You are a linguistic gloss reconciliation expert. Compare these #{glosses.size} glosses of the same #{from_name} text word by word and produce the best consensus gloss.

        Original text: #{text}

        #{parts}

        Rules:
        - For grammar labels: pick the most accurate morphological analysis.
        - For agrammatical markings (*wrong*correction): keep ONLY if multiple models agree on both the error AND the correction. If models disagree or only one marks it, output the word unmarked with its grammar labels.
        - For translations (if present): pick the most context-appropriate #{to_name} translation.
        - Output format: #{format_instruction}
        - Keep punctuation in place without glossing it.
        - Output ONLY the reconciled gloss line. One line, words separated by spaces.
      PROMPT

      message = @client.messages.create(
        model: @model,
        max_tokens: 4096,
        messages: [{ role: "user", content: prompt }]
      )
      message.content.first.text.strip
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
      Proper names in inflected languages decline as nouns — gloss as n.prop, NOT as adjectives. E.g. Pirini(n.prop.f.D.sg) not Pirini(adj.f.D.sg).
      Agrammatical forms: if a word has a clear grammatical error (wrong declension/conjugation ending, obvious misspelling), mark as *original*correction(grammar). Only mark when you are certain the correction is valid. When unsure, gloss the word as-is without marking.
    ABBR
  end
end
