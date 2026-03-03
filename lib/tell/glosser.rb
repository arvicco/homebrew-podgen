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

                Example: svet(n.m.N.sg)world je(v.aux.3p.pres)is velik(adj.m.sg.N)big

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
      Abbreviations (dot-separated inside parens):
      n=noun v=verb adj=adjective adv=adverb pr=preposition conj=conjunction pron=pronoun det=determiner part=particle num=numeral interj=interjection
      Cases: N=nominative G=genitive D=dative A=accusative L=locative I=instrumental V=vocative
      Number: sg=singular pl=plural du=dual
      Verb: inf=infinitive ind=indicative imp=imperative cond=conditional pres=present past=past fut=future 1p/2p/3p=person aux=auxiliary
      Gender: m=masculine f=feminine n=neuter
      Other: def=definite indef=indefinite refl=reflexive neg=negation comp=comparative sup=superlative dim=diminutive perf=perfective imperf=imperfective
    ABBR
  end
end
