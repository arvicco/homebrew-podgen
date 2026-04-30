# frozen_string_literal: true

# Shared ISO 639-1 → English language name mapping.
# Used by TranslationAgent (news pipeline) and Tell (pronunciation tool).
LANGUAGE_NAMES = {
  "en" => "English",
  "es" => "Spanish",
  "fr" => "French",
  "de" => "German",
  "it" => "Italian",
  "pt" => "Portuguese",
  "nl" => "Dutch",
  "pl" => "Polish",
  "ja" => "Japanese",
  "ko" => "Korean",
  "zh" => "Chinese",
  "ar" => "Arabic",
  "hi" => "Hindi",
  "ru" => "Russian",
  "tr" => "Turkish",
  "sv" => "Swedish",
  "da" => "Danish",
  "no" => "Norwegian",
  "fi" => "Finnish",
  "uk" => "Ukrainian",
  "cs" => "Czech",
  "ro" => "Romanian",
  "hu" => "Hungarian",
  "el" => "Greek",
  "he" => "Hebrew",
  "th" => "Thai",
  "vi" => "Vietnamese",
  "id" => "Indonesian",
  "ms" => "Malay",
  "sl" => "Slovenian",
  "hr" => "Croatian",
  "sr" => "Serbian",
  "bg" => "Bulgarian",
  "sk" => "Slovak",
  "lt" => "Lithuanian",
  "lv" => "Latvian",
  "et" => "Estonian",
  # Country-code aliases: people commonly write the ISO 3166 country code
  # instead of the ISO 639-1 language code. Accept both.
  "jp" => "Japanese", # canonical: ja
  "cn" => "Chinese",  # canonical: zh
  "kr" => "Korean"    # canonical: ko
}.freeze

# Same map but with each language's name written in its own script.
# Used for user-facing UI (site language switcher) where readers expect to
# see "日本語" rather than "Japanese". Keep LANGUAGE_NAMES for prompts and
# any English-language display.
LANGUAGE_NATIVE_NAMES = {
  "en" => "English",
  "es" => "Español",
  "fr" => "Français",
  "de" => "Deutsch",
  "it" => "Italiano",
  "pt" => "Português",
  "nl" => "Nederlands",
  "pl" => "Polski",
  "ja" => "日本語",
  "ko" => "한국어",
  "zh" => "中文",
  "ar" => "العربية",
  "hi" => "हिन्दी",
  "ru" => "Русский",
  "tr" => "Türkçe",
  "sv" => "Svenska",
  "da" => "Dansk",
  "no" => "Norsk",
  "fi" => "Suomi",
  "uk" => "Українська",
  "cs" => "Čeština",
  "ro" => "Română",
  "hu" => "Magyar",
  "el" => "Ελληνικά",
  "he" => "עברית",
  "th" => "ไทย",
  "vi" => "Tiếng Việt",
  "id" => "Bahasa Indonesia",
  "ms" => "Bahasa Melayu",
  "sl" => "Slovenščina",
  "hr" => "Hrvatski",
  "sr" => "Српски",
  "bg" => "Български",
  "sk" => "Slovenčina",
  "lt" => "Lietuvių",
  "lv" => "Latviešu",
  "et" => "Eesti",
  # Country-code aliases (mirror LANGUAGE_NAMES)
  "jp" => "日本語",
  "cn" => "中文",
  "kr" => "한국어"
}.freeze
