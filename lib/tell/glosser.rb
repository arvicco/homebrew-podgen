# frozen_string_literal: true

module Tell
  class Glosser
    def initialize(api_key)
      require "anthropic"
      @client = Anthropic::Client.new(api_key: api_key, timeout: 15, max_retries: 1)
      @model = ENV.fetch("TELL_GLOSS_MODEL", "claude-haiku-4-5-20251001")
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

                Example: svet(n.m.N.sg)world je(v.aux.3p.pres)is velik(adj.m.N.sg)big

                #{GRAMMAR_ABBREVIATIONS}

                Output ONLY the glossed line. Keep original word order. One line, words separated by spaces.

                #{text}
              PROMPT
            }
          ]
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
    ABBR
  end
end
