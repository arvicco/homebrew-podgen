# frozen_string_literal: true

# Phonetic system definitions per language.
# Ordered hash: first key = default system for that language.
# Config keys: label (UI), standalone (prompt), bracket (gloss prompt), separator (word delimiter).
#
# Extracted from Tell::Glosser for clarity. Accessed via Glosser.systems_for / .default_system.

module Tell
  module PhoneticSystems
    SYSTEMS = begin
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

    ALIASES = { "kana" => "hiragana" }.freeze
  end
end
