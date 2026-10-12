# frozen_string_literal: true

require_relative "../test_helper"
require "guidelines_parser"

# P3-0 H4 characterization harness: pins the CURRENT behavior of the 14
# near-identical `parse_*_section` list walkers in lib/guidelines_parser.rb
# before a refactor consolidates them. Every parser is run against the same
# matrix of input shapes (SHAPES) built from a per-parser item pair (SPECS);
# EXPECTED pins the exact [return value, warnings] for each cell.
#
# These tests describe what the code does, not what it should do. Where the
# parsers disagree on the same input shape the disagreement is pinned and
# marked "FLAG" in the cross-parser tests at the bottom.
#
# The 14 parsers (grep "def parse_.*_section"): kv (shared iterator), podcast,
# audio, image, site, language, transcription_engine, lingq, youtube, twitter,
# translation_glossary, vocabulary, links, sources.
class TestCharacterizationGuidelinesSections < Minitest::Test
  PODCAST_DIR = "/pod" # resolve_path only joins strings; no I/O happens

  # parser method => [heading, item_a, item_b, duplicate_of_a, autolink_item]
  SPECS = {
    parse_kv_section: ["Generic", "alpha: one", "beta: two", "alpha: uno", "url: [https://ex.com/a](https://ex.com/a)"],
    parse_podcast_section: ["Podcast", "name: Show", "author: Jane", "name: Other", "website: [https://ex.com](https://ex.com)"],
    parse_audio_section: ["Audio", "language: it", "skip: 30", "language: sl", "url: [https://ex.com/a.mp3](https://ex.com/a.mp3)"],
    parse_image_section: ["Image", "font: Arial", "font_size: 40", "font: Helvetica", "image: [https://ex.com/i.png](https://ex.com/i.png)"],
    parse_site_section: ["Site", "footer: Hello", "accent: red", "footer: Bye", "footer: [https://ex.com](https://ex.com)"],
    parse_language_section: ["Language", "en", "es: VOICE_ES", "en: VOICE_EN", "fr: [https://ex.com](https://ex.com)"],
    parse_transcription_engine_section: ["Transcription Engine", "open", "groq", "open", "[https://ex.com](https://ex.com)"],
    parse_lingq_section: ["LingQ", "token: abc", "level: 3", "token: xyz", "image: [https://ex.com/i.png](https://ex.com/i.png)"],
    parse_youtube_section: ["YouTube", "playlist: PL1", "category: Education", "playlist: PL2", "playlist: [https://youtube.com/p](https://youtube.com/p)"],
    parse_twitter_section: ["Twitter", "template: Hello", "since: 5", "template: Bye", "template: [https://ex.com](https://ex.com)"],
    parse_translation_glossary_section: ["Translation Glossary", "jp:\n  - Bitcoin: BTC", "es:\n  - mining: mineria", "jp:\n  - Bitcoin: XBT", "jp:\n  - site: [https://ex.com](https://ex.com)"],
    parse_vocabulary_section: ["Vocabulary", "level: B1", "max: 5", "level: C2", "filter: [https://ex.com](https://ex.com)"],
    parse_links_section: ["Links", "show: true", "title: More", "show: false", "title: [https://ex.com](https://ex.com)"],
    parse_sources_section: ["Sources", "exa", "hn", "exa: x", "rss:\n  - [https://ex.com/feed](https://ex.com/feed) skip: 30"]
  }.freeze

  # shape => builder(heading, a, b, dup_of_a, autolink) -> guidelines text
  SHAPES = {
    present: ->(h, a, b, _c, _d) { "## #{h}\n- #{a}\n- #{b}\n" },
    absent: ->(_h, a, _b, _c, _d) { "## Elsewhere\n- #{a}\n" },
    empty: ->(h, _a, _b, _c, _d) { "## #{h}\n\n## Next\n- zeta: z\n" },
    heading_at_eof_no_newline: ->(h, _a, _b, _c, _d) { "# Doc\n## #{h}" },
    last_item_no_newline: ->(h, a, b, _c, _d) { "## #{h}\n- #{a}\n- #{b}" },
    sub_bullets: ->(h, a, b, _c, _d) { "## #{h}\n- #{a}\n  - sub: one\n- #{b}\n" },
    star_bullets: ->(h, a, b, _c, _d) { "## #{h}\n* #{a}\n- #{b}\n" },
    blank_lines_inside: ->(h, a, b, _c, _d) { "## #{h}\n- #{a}\n\n\n- #{b}\n" },
    followed_by_heading: ->(h, a, b, _c, _d) { "## #{h}\n- #{a}\n## Next\n- #{b}\n" },
    h3_inside: ->(h, a, b, _c, _d) { "## #{h}\n- #{a}\n### Sub\n- #{b}\n" },
    h1_inside: ->(h, a, b, _c, _d) { "## #{h}\n- #{a}\n# Top\n- #{b}\n" },
    bare_key: ->(h, a, b, _c, _d) { "## #{h}\n- #{a.split(":").first}\n- #{b}\n" },
    duplicate_keys: ->(h, a, _b, c, _d) { "## #{h}\n- #{a}\n- #{c}\n" },
    autolinked_url: ->(h, a, _b, _c, d) { "## #{h}\n- #{a}\n- #{d}\n" },
    hash_comment: ->(h, a, b, _c, _d) { "## #{h}\n- #{a} # note\n- #{b}\n" },
    indented_item: ->(h, a, b, _c, _d) { "## #{h}\n  - #{a}\n- #{b}\n" },
    double_space_bullet: ->(h, a, b, _c, _d) { "## #{h}\n-  #{a}\n- #{b}\n" },
    crlf: ->(h, a, b, _c, _d) { "## #{h}\r\n- #{a}\r\n- #{b}\r\n" }
  }.freeze

  # parser => shape => [return value, warnings appended by that parser]
  # :raises_no_method_error marks a cell where the parser raises.
  EXPECTED = {
    parse_kv_section: {
      present: [{"alpha" => "one", "beta" => "two"}, []],
      absent: [nil, []],
      empty: [{}, []],
      heading_at_eof_no_newline: [nil, []],
      last_item_no_newline: [{"alpha" => "one", "beta" => "two"}, []],
      sub_bullets: [{"alpha" => "one", "beta" => "two"}, []],
      star_bullets: [{"beta" => "two"}, []],
      blank_lines_inside: [{"alpha" => "one", "beta" => "two"}, []],
      followed_by_heading: [{"alpha" => "one"}, []],
      h3_inside: [{"alpha" => "one", "beta" => "two"}, []],
      h1_inside: [{"alpha" => "one", "beta" => "two"}, []],
      bare_key: [{"alpha" => nil, "beta" => "two"}, []],
      duplicate_keys: [{"alpha" => "uno"}, []],
      autolinked_url: [{"alpha" => "one", "url" => "[https://ex.com/a](https://ex.com/a)"}, []],
      hash_comment: [{"alpha" => "one", "beta" => "two"}, []],
      indented_item: [{"beta" => "two"}, []],
      double_space_bullet: [{"beta" => "two"}, []],
      crlf: [{"alpha" => "one", "beta" => "two"}, []]
    },
    parse_podcast_section: {
      present: [{name: "Show", author: "Jane"}, []],
      absent: [{}, []],
      empty: [{}, []],
      heading_at_eof_no_newline: [{}, []],
      last_item_no_newline: [{name: "Show", author: "Jane"}, []],
      sub_bullets: [{name: "Show", author: "Jane"}, []],
      star_bullets: [{author: "Jane"}, []],
      blank_lines_inside: [{name: "Show", author: "Jane"}, []],
      followed_by_heading: [{name: "Show"}, []],
      h3_inside: [{name: "Show", author: "Jane"}, []],
      h1_inside: [{name: "Show", author: "Jane"}, []],
      bare_key: [{author: "Jane"}, []],
      duplicate_keys: [{name: "Other"}, []],
      autolinked_url: [{name: "Show", website: "[https://ex.com](https://ex.com)"}, []],
      hash_comment: [{name: "Show # note", author: "Jane"}, []],
      indented_item: [{author: "Jane"}, []],
      double_space_bullet: [{author: "Jane"}, []],
      crlf: [{name: "Show", author: "Jane"}, []]
    },
    parse_audio_section: {
      present: [{language: "it", skip: 30.0}, []],
      absent: [{}, []],
      empty: [{}, []],
      heading_at_eof_no_newline: [{}, []],
      last_item_no_newline: [{language: "it", skip: 30.0}, []],
      sub_bullets: [{language: "it", skip: 30.0}, ["Audio section: indented line '- sub: one' is ignored (top-level keys must start at column 0 with '- ')"]],
      star_bullets: [{skip: 30.0}, []],
      blank_lines_inside: [{language: "it", skip: 30.0}, []],
      followed_by_heading: [{language: "it"}, []],
      h3_inside: [{language: "it", skip: 30.0}, []],
      h1_inside: [{language: "it", skip: 30.0}, []],
      bare_key: [{skip: 30.0}, []],
      duplicate_keys: [{language: "sl"}, []],
      autolinked_url: [{language: "it", url: "[https://ex.com/a.mp3](https://ex.com/a.mp3)"}, []],
      hash_comment: [{language: "it # note", skip: 30.0}, []],
      indented_item: [{skip: 30.0}, ["Audio section: indented line '- language: it' is ignored (top-level keys must start at column 0 with '- ')"]],
      double_space_bullet: [{skip: 30.0}, []],
      crlf: [{language: "it", skip: 30.0}, []]
    },
    parse_image_section: {
      present: [{font: "Arial", font_size: 40}, []],
      absent: [{}, []],
      empty: [{}, []],
      heading_at_eof_no_newline: [{}, []],
      last_item_no_newline: [{font: "Arial", font_size: 40}, []],
      sub_bullets: [{font: "Arial", font_size: 40}, []],
      star_bullets: [{font_size: 40}, []],
      blank_lines_inside: [{font: "Arial", font_size: 40}, []],
      followed_by_heading: [{font: "Arial"}, []],
      h3_inside: [{font: "Arial", font_size: 40}, []],
      h1_inside: [{font: "Arial", font_size: 40}, []],
      bare_key: [{font: nil, font_size: 40}, []],
      duplicate_keys: [{font: "Helvetica"}, []],
      autolinked_url: [{font: "Arial", image: "[https://ex.com/i.png](https://ex.com/i.png)"}, []],
      hash_comment: [{font: "Arial", font_size: 40}, []],
      indented_item: [{font_size: 40}, []],
      double_space_bullet: [{font_size: 40}, []],
      crlf: [{font: "Arial", font_size: 40}, []]
    },
    parse_site_section: {
      present: [{footer: "Hello", accent: "red"}, []],
      absent: [{}, []],
      empty: [{}, []],
      heading_at_eof_no_newline: [{}, []],
      last_item_no_newline: [{footer: "Hello", accent: "red"}, []],
      sub_bullets: [{footer: "Hello", accent: "red"}, []],
      star_bullets: [{accent: "red"}, []],
      blank_lines_inside: [{footer: "Hello", accent: "red"}, []],
      followed_by_heading: [{footer: "Hello"}, []],
      h3_inside: [{footer: "Hello", accent: "red"}, []],
      h1_inside: [{footer: "Hello", accent: "red"}, []],
      bare_key: [{footer: nil, accent: "red"}, []],
      duplicate_keys: [{footer: "Bye"}, []],
      autolinked_url: [{footer: "[https://ex.com](https://ex.com)"}, []],
      hash_comment: [{footer: "Hello", accent: "red"}, []],
      indented_item: [{accent: "red"}, []],
      double_space_bullet: [{accent: "red"}, []],
      crlf: [{footer: "Hello", accent: "red"}, []]
    },
    parse_language_section: {
      present: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      absent: [[{"code" => "en"}], []],
      empty: [[{"code" => "en"}], []],
      heading_at_eof_no_newline: [[{"code" => "en"}], []],
      last_item_no_newline: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      sub_bullets: [[{"code" => "en"}, {"code" => "sub", "voice_id" => "one"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      star_bullets: [[{"code" => "es", "voice_id" => "VOICE_ES"}], []],
      blank_lines_inside: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      followed_by_heading: [[{"code" => "en"}], []],
      h3_inside: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      h1_inside: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      bare_key: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      duplicate_keys: [[{"code" => "en"}, {"code" => "en", "voice_id" => "VOICE_EN"}], []],
      autolinked_url: [[{"code" => "en"}, {"code" => "fr"}], []],
      hash_comment: [[{"code" => "en # note"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      indented_item: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      double_space_bullet: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []],
      crlf: [[{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES"}], []]
    },
    parse_transcription_engine_section: {
      present: [["open", "groq"], []],
      absent: [["open"], []],
      empty: [["open"], []],
      heading_at_eof_no_newline: [["open"], []],
      last_item_no_newline: [["open", "groq"], []],
      sub_bullets: [["open", "sub: one", "groq"], []],
      star_bullets: [["groq"], []],
      blank_lines_inside: [["open", "groq"], []],
      followed_by_heading: [["open"], []],
      h3_inside: [["open", "groq"], []],
      h1_inside: [["open", "groq"], []],
      bare_key: [["open", "groq"], []],
      duplicate_keys: [["open", "open"], []],
      autolinked_url: [["open", "[https://ex.com](https://ex.com)"], []],
      hash_comment: [["open # note", "groq"], []],
      indented_item: [["open", "groq"], []],
      double_space_bullet: [["open", "groq"], []],
      crlf: [["open", "groq"], []]
    },
    parse_lingq_section: {
      present: [{token: "abc", level: 3}, []],
      absent: [nil, []],
      empty: [nil, []],
      heading_at_eof_no_newline: [nil, []],
      last_item_no_newline: [{token: "abc", level: 3}, []],
      sub_bullets: [{token: "abc", level: 3}, []],
      star_bullets: [{level: 3}, []],
      blank_lines_inside: [{token: "abc", level: 3}, []],
      followed_by_heading: [{token: "abc"}, []],
      h3_inside: [{token: "abc", level: 3}, []],
      h1_inside: [{token: "abc", level: 3}, []],
      bare_key: [{token: nil, level: 3}, []],
      duplicate_keys: [{token: "xyz"}, []],
      autolinked_url: [{token: "abc", image: "/pod/[https://ex.com/i.png](https://ex.com/i.png)"}, []],
      hash_comment: [{token: "abc", level: 3}, []],
      indented_item: [{level: 3}, []],
      double_space_bullet: [{level: 3}, []],
      crlf: [{token: "abc", level: 3}, []]
    },
    parse_youtube_section: {
      present: [{playlist: "PL1", category: "Education"}, []],
      absent: [nil, []],
      empty: [nil, []],
      heading_at_eof_no_newline: [nil, []],
      last_item_no_newline: [{playlist: "PL1", category: "Education"}, []],
      sub_bullets: [{playlist: "PL1", category: "Education"}, []],
      star_bullets: [{category: "Education"}, []],
      blank_lines_inside: [{playlist: "PL1", category: "Education"}, []],
      followed_by_heading: [{playlist: "PL1"}, []],
      h3_inside: [{playlist: "PL1", category: "Education"}, []],
      h1_inside: [{playlist: "PL1", category: "Education"}, []],
      bare_key: [{playlist: nil, category: "Education"}, []],
      duplicate_keys: [{playlist: "PL2"}, []],
      autolinked_url: [{playlist: "[https://youtube.com/p](https://youtube.com/p)"}, []],
      hash_comment: [{playlist: "PL1", category: "Education"}, []],
      indented_item: [{category: "Education"}, []],
      double_space_bullet: [{category: "Education"}, []],
      crlf: [{playlist: "PL1", category: "Education"}, []]
    },
    parse_twitter_section: {
      present: [{template: "Hello", since: 5}, []],
      absent: [nil, []],
      empty: [nil, []],
      heading_at_eof_no_newline: [nil, []],
      last_item_no_newline: [{template: "Hello", since: 5}, []],
      sub_bullets: [{template: "Hello", since: 5}, []],
      star_bullets: [{since: 5}, []],
      blank_lines_inside: [{template: "Hello", since: 5}, []],
      followed_by_heading: [{template: "Hello"}, []],
      h3_inside: [{template: "Hello", since: 5}, []],
      h1_inside: [{template: "Hello", since: 5}, []],
      bare_key: [{template: nil, since: 5}, []],
      duplicate_keys: [{template: "Bye"}, []],
      autolinked_url: [{template: "[https://ex.com](https://ex.com)"}, []],
      hash_comment: [{template: "Hello", since: 5}, []],
      indented_item: [{since: 5}, []],
      double_space_bullet: [{since: 5}, []],
      crlf: [{template: "Hello", since: 5}, []]
    },
    parse_translation_glossary_section: {
      present: [{"jp" => {"Bitcoin" => "BTC"}, "es" => {"mining" => "mineria"}}, []],
      absent: [{}, []],
      empty: [{}, []],
      heading_at_eof_no_newline: [{}, []],
      last_item_no_newline: [{"jp" => {"Bitcoin" => "BTC"}, "es" => {"mining" => "mineria"}}, []],
      sub_bullets: [{"jp" => {"Bitcoin" => "BTC", "sub" => "one"}, "es" => {"mining" => "mineria"}}, []],
      star_bullets: [{"es" => {"mining" => "mineria"}}, []],
      blank_lines_inside: [{"jp" => {"Bitcoin" => "BTC"}, "es" => {"mining" => "mineria"}}, []],
      followed_by_heading: [{"jp" => {"Bitcoin" => "BTC"}}, []],
      h3_inside: [{"jp" => {"Bitcoin" => "BTC"}, "es" => {"mining" => "mineria"}}, []],
      h1_inside: [{"jp" => {"Bitcoin" => "BTC"}, "es" => {"mining" => "mineria"}}, []],
      bare_key: [{"es" => {"mining" => "mineria"}}, []],
      duplicate_keys: [{"jp" => {"Bitcoin" => "XBT"}}, []],
      autolinked_url: [{"jp" => {"Bitcoin" => "BTC", "site" => "[https://ex.com](https://ex.com)"}}, []],
      hash_comment: [{"jp" => {"Bitcoin" => "BTC # note"}, "es" => {"mining" => "mineria"}}, []],
      indented_item: [{"es" => {"mining" => "mineria"}}, []],
      double_space_bullet: [{"es" => {"mining" => "mineria"}}, []],
      crlf: [{"jp" => {"Bitcoin" => "BTC"}, "es" => {"mining" => "mineria"}}, []]
    },
    parse_vocabulary_section: {
      present: [{level: "B1", max: 5}, []],
      absent: [nil, []],
      empty: [nil, []],
      heading_at_eof_no_newline: [nil, []],
      last_item_no_newline: [{level: "B1", max: 5}, []],
      sub_bullets: [{level: "B1", max: 5}, []],
      star_bullets: [{max: 5}, []],
      blank_lines_inside: [{level: "B1", max: 5}, []],
      followed_by_heading: [{level: "B1"}, []],
      h3_inside: [{level: "B1", max: 5}, []],
      h1_inside: [{level: "B1", max: 5}, []],
      bare_key: :raises_no_method_error,
      duplicate_keys: [{level: "C2"}, []],
      autolinked_url: [{level: "B1", filter: "[https://ex.com](https://ex.com)"}, []],
      hash_comment: [{level: "B1", max: 5}, []],
      indented_item: [{max: 5}, []],
      double_space_bullet: [{max: 5}, []],
      crlf: [{level: "B1", max: 5}, []]
    },
    parse_links_section: {
      present: [{show: true, title: "More"}, []],
      absent: [nil, []],
      empty: [nil, []],
      heading_at_eof_no_newline: [nil, []],
      last_item_no_newline: [{show: true, title: "More"}, []],
      sub_bullets: [{show: true, title: "More"}, []],
      star_bullets: [nil, []],
      blank_lines_inside: [{show: true, title: "More"}, []],
      followed_by_heading: [{show: true}, []],
      h3_inside: [{show: true, title: "More"}, []],
      h1_inside: [{show: true, title: "More"}, []],
      bare_key: [nil, []],
      duplicate_keys: [nil, []],
      autolinked_url: [{show: true, title: "[https://ex.com](https://ex.com)"}, []],
      hash_comment: [{show: true, title: "More"}, []],
      indented_item: [nil, []],
      double_space_bullet: [nil, []],
      crlf: [{show: true, title: "More"}, []]
    },
    parse_sources_section: {
      present: [{"exa" => true, "hn" => true}, []],
      absent: [{"exa" => true}, []],
      empty: [{"exa" => true}, []],
      heading_at_eof_no_newline: [{"exa" => true}, []],
      last_item_no_newline: [{"exa" => true, "hn" => true}, []],
      sub_bullets: [{"exa" => true, "hn" => true}, []],
      star_bullets: [{"hn" => true}, []],
      blank_lines_inside: [{"exa" => true, "hn" => true}, []],
      followed_by_heading: [{"exa" => true}, []],
      h3_inside: [{"exa" => true, "hn" => true}, []],
      h1_inside: [{"exa" => true, "hn" => true}, []],
      bare_key: [{"exa" => true, "hn" => true}, []],
      duplicate_keys: [{"exa" => ["x"]}, []],
      autolinked_url: [{"exa" => true, "rss" => [{url: "[https://ex.com/feed](https://ex.com/feed)", skip: 30.0}]}, []],
      hash_comment: [{"exa # note" => true, "hn" => true}, []],
      indented_item: [{"hn" => true}, []],
      double_space_bullet: [{"hn" => true}, []],
      crlf: [{"exa" => true, "hn" => true}, []]
    }
  }.freeze

  # --- matrix: one generated test per (parser, shape) cell ---

  SPECS.each_key do |method|
    SHAPES.each_key do |shape|
      define_method(:"test_#{method}_#{shape}_returns_pinned_structure") do
        expected = EXPECTED.fetch(method).fetch(shape)

        if expected == :raises_no_method_error
          assert_raises(NoMethodError) { run_cell(method, shape) }
        else
          result, warnings = run_cell(method, shape)
          assert_equal expected, [result, warnings]
        end
      end
    end
  end

  def test_expected_table_covers_every_parser_and_shape
    parsers = GuidelinesParser.private_instance_methods(false).grep(/\Aparse_.*_section\z/)

    assert_equal 14, parsers.size
    assert_equal parsers.sort, SPECS.keys.sort
    EXPECTED.each_value { |cells| assert_equal SHAPES.keys, cells.keys }
  end

  # --- shared document: every public reader on one full guidelines.md ---

  SHARED_DOC = <<~MD
    # Shared Characterization Show

    ## Podcast
    - name: Shared Show
    - author: Jane Doe
    - language:
      - en
      - es: VOICE_ES translator: openai

    ## Format
    Short episodes.

    ## Audio
    - skip: 1:30
    - cut: 10
    - autotrim
    - engine:
      - open
      - groq

    ## Image
    - cover: cover.jpg
    - base_image: base.png
    - font_size: 48
    - text_width: 900

    ## Site
    - accent: #ff0000 # brand red
    - footer: Made with podgen
    - playback_speed: 1.25
    - show_transcript: false

    ## Sources
    - exa
    - hn: ai, ruby
    - rss:
      - https://ex.com/feed skip: 38 autotrim
      - https://ex.com/plain

    ## LingQ
    - collection: 123
    - tags: one, two
    - image: lingq.png

    ## YouTube
    - playlist: PL123
    - privacy: unlisted
    - tags: a, b

    ## Twitter
    - template: New: {title}
    - since: 10
    - languages: EN, sl

    ## Translation Glossary
    - jp:
      - Bitcoin: ビットコイン
    - ES:
      - mining: minería

    ## Vocabulary
    - level: b2
    - max: 12
    - priority: frequent

    ## Links
    - show: true
    - position: inline
    - max: 3
  MD

  SHARED_LANGUAGES = [{"code" => "en"}, {"code" => "es", "voice_id" => "VOICE_ES", "translator" => "openai"}].freeze

  SHARED_EXPECTED = {
    podcast_section: {name: "Shared Show", author: "Jane Doe", languages: SHARED_LANGUAGES},
    audio_section: {skip: 90.0, cut: 10.0, autotrim: true, engines: ["open", "groq"]},
    image_section: {cover: "cover.jpg", base_image: "/pod/base.png", font_size: 48, width: 900},
    sources: {"exa" => true, "hn" => ["ai", "ruby"], "rss" => [{url: "https://ex.com/feed", skip: 38.0, autotrim: true}, "https://ex.com/plain"]},
    site_config: {accent: "#ff0000", footer: "Made with podgen", playback_speed: 1.25, show_transcript: false},
    lingq_config: {collection: 123, tags: ["one", "two"], image: "/pod/lingq.png"},
    youtube_config: {playlist: "PL123", privacy: "unlisted", tags: ["a", "b"]},
    twitter_config: {template: "New: {title}", since: 10, languages: ["en", "sl"]},
    links_config: {show: true, position: "inline", max: 3},
    vocabulary_config: {level: "B2", max: 12, priority: "frequent"},
    translation_glossary: {"jp" => {"Bitcoin" => "ビットコイン"}, "es" => {"mining" => "minería"}},
    languages: SHARED_LANGUAGES,
    transcription_engines: ["open", "groq"]
  }.freeze

  def test_section_readers_shared_document_return_pinned_structures
    parser = GuidelinesParser.new(SHARED_DOC, podcast_dir: PODCAST_DIR)

    assert_equal GuidelinesParser::SECTION_READERS.sort, SHARED_EXPECTED.keys.sort
    SHARED_EXPECTED.each do |reader, expected|
      assert_equal expected, parser.public_send(reader), reader.to_s
    end
    assert_empty parser.warnings
  end

  # --- bare recognized key (a "- key" line with no colon) ---
  # parse_kv_section yields (key, nil); handlers that call a method on the
  # value raise, which prime! converts into a warning.

  BARE_KEY_RAISES = {
    "## YouTube\n- tags\n" => [:youtube_config, "split"],
    "## LingQ\n- tags\n" => [:lingq_config, "split"],
    "## LingQ\n- image\n" => [:lingq_config, "start_with?"],
    "## Image\n- base_image\n" => [:image_section, "start_with?"],
    "## Twitter\n- languages\n" => [:twitter_config, "split"],
    "## Site\n- accent\n" => [:site_config, "gsub"],
    "## Vocabulary\n- level\n" => [:vocabulary_config, "upcase"]
  }.freeze

  def test_kv_readers_bare_recognized_key_raises_no_method_error
    BARE_KEY_RAISES.each do |text, (reader, meth)|
      parser = GuidelinesParser.new(text, podcast_dir: PODCAST_DIR)

      error = assert_raises(NoMethodError, text) { parser.public_send(reader) }
      assert_includes error.message, meth
    end
  end

  def test_warnings_bare_recognized_key_reported_as_unparseable
    BARE_KEY_RAISES.each do |text, (reader, _meth)|
      warnings = GuidelinesParser.new(text, podcast_dir: PODCAST_DIR).warnings

      assert_equal 1, warnings.size, text
      assert warnings.first.start_with?("#{reader}: unparseable — NoMethodError: "), warnings.first
    end
  end

  def test_kv_readers_bare_recognized_key_coerces_nil_silently
    cases = {
      "## Site\n- playback_speed\n" => [:site_config, {playback_speed: 0.0}],
      "## Site\n- show_duration\n" => [:site_config, {show_duration: true}],
      "## Image\n- font_size\n" => [:image_section, {font_size: 0}],
      "## Vocabulary\n- max\n" => [:vocabulary_config, nil],
      "## Links\n- show\n" => [:links_config, nil]
    }

    cases.each do |text, (reader, expected)|
      parser = GuidelinesParser.new(text, podcast_dir: PODCAST_DIR)
      if expected.nil?
        assert_nil parser.public_send(reader), text
      else
        assert_equal expected, parser.public_send(reader), text
      end
      assert_empty parser.warnings, text
    end
  end

  # --- cross-parser disagreements (FLAG) ---
  # Each test reads the matrix above and pins which parsers fall on which
  # side of a disagreement, so a consolidating refactor sees every one.

  KV_FAMILY = %i[
    parse_kv_section parse_image_section parse_site_section parse_lingq_section
    parse_youtube_section parse_twitter_section parse_vocabulary_section parse_links_section
  ].freeze

  def test_cross_parser_absent_section_return_value_disagrees
    # FLAG: missing section yields nil, {} or a non-empty default by parser.
    by_value = SPECS.keys.group_by { |m| EXPECTED[m][:absent].first }

    assert_equal %i[parse_kv_section parse_lingq_section parse_youtube_section parse_twitter_section parse_vocabulary_section parse_links_section], by_value[nil]
    assert_equal %i[parse_podcast_section parse_audio_section parse_image_section parse_site_section parse_translation_glossary_section], by_value[{}]
    assert_equal [[{"code" => "en"}], ["open"], {"exa" => true}], (by_value.keys - [nil, {}])
  end

  def test_cross_parser_empty_and_heading_at_eof_match_absent_except_kv
    SPECS.each_key do |m|
      assert_equal EXPECTED[m][:absent], EXPECTED[m][:heading_at_eof_no_newline], m.to_s
      next if m == :parse_kv_section

      assert_equal EXPECTED[m][:absent], EXPECTED[m][:empty], m.to_s
    end
    # parse_kv_section alone tells "missing" (nil) from "empty" ({}).
    assert_nil EXPECTED[:parse_kv_section][:absent].first
    assert_equal({}, EXPECTED[:parse_kv_section][:empty].first)
  end

  def test_cross_parser_hash_comment_stripped_only_by_kv_family
    # FLAG: " # note" after a value is stripped by parse_kv_section users,
    # kept verbatim by podcast/audio/language/transcription_engine/glossary,
    # and for sources kept on a bare item ("exa # note" becomes the key) but
    # stripped on an inline "key: v1, v2 # c" item.
    keeps = SPECS.keys.select { |m| EXPECTED[m][:hash_comment].inspect.include?("# note") }

    assert_equal %i[
      parse_podcast_section parse_audio_section parse_language_section
      parse_transcription_engine_section parse_translation_glossary_section parse_sources_section
    ], keeps
    assert_empty KV_FAMILY & keeps
  end

  def test_cross_parser_indented_and_double_space_items_accepted_only_by_strip_first_parsers
    # FLAG: language and transcription_engine strip the line before matching
    # "- ", so indented items and "-  x" are accepted; every other parser
    # requires /^- \S/ and drops them (audio additionally warns on indented).
    accepting = SPECS.keys.select { |m| EXPECTED[m][:indented_item] == EXPECTED[m][:present] }

    assert_equal %i[parse_language_section parse_transcription_engine_section], accepting
    assert_equal accepting, SPECS.keys.select { |m| EXPECTED[m][:double_space_bullet] == EXPECTED[m][:present] }
    warners = SPECS.keys.reject { |m| EXPECTED[m][:indented_item].last.empty? }
    assert_equal %i[parse_audio_section], warners
  end

  def test_cross_parser_sub_bullets_handling_disagrees
    # FLAG: an unexpected indented "  - sub: one" is ignored by most parsers,
    # warned about by audio, merged into the current language by the
    # glossary, and FLATTENED into a top-level entry by language
    # ({"code" => "sub", "voice_id" => "one"}) and transcription_engine
    # ("sub: one" becomes an engine code).
    unchanged = SPECS.keys.select { |m| EXPECTED[m][:sub_bullets] == EXPECTED[m][:present] }

    assert_equal %i[
      parse_kv_section parse_podcast_section parse_image_section parse_site_section
      parse_lingq_section parse_youtube_section parse_twitter_section
      parse_vocabulary_section parse_links_section parse_sources_section
    ], unchanged
    assert_includes EXPECTED[:parse_language_section][:sub_bullets].first, {"code" => "sub", "voice_id" => "one"}
    assert_includes EXPECTED[:parse_transcription_engine_section][:sub_bullets].first, "sub: one"
    assert_equal "one", EXPECTED[:parse_translation_glossary_section][:sub_bullets].first["jp"]["sub"]
    assert_equal 1, EXPECTED[:parse_audio_section][:sub_bullets].last.size
  end

  def test_cross_parser_duplicate_keys_last_wins_except_list_parsers
    # FLAG: hash-shaped parsers keep the last value; list parsers append both
    # (no dedupe); links drops the whole section when the later "show: false"
    # wins; sources lets "- exa: x" replace the earlier bare "- exa".
    assert_equal [{"code" => "en"}, {"code" => "en", "voice_id" => "VOICE_EN"}], EXPECTED[:parse_language_section][:duplicate_keys].first
    assert_equal ["open", "open"], EXPECTED[:parse_transcription_engine_section][:duplicate_keys].first
    assert_nil EXPECTED[:parse_links_section][:duplicate_keys].first
    assert_equal({"exa" => ["x"]}, EXPECTED[:parse_sources_section][:duplicate_keys].first)
  end

  def test_cross_parser_star_bullets_dropped_silently_by_all
    # Consistent, but silent: "* item" is never parsed and never warned.
    SPECS.each_key do |m|
      result, warnings = EXPECTED[m][:star_bullets]
      refute_equal EXPECTED[m][:present].first, result, m.to_s
      assert_empty warnings, m.to_s
    end
  end

  def test_cross_parser_only_h2_terminates_a_section
    # Consistent: "### Sub" and "# Top" do not end a section; "## Next" does.
    SPECS.each_key do |m|
      assert_equal EXPECTED[m][:present], EXPECTED[m][:h3_inside], m.to_s
      assert_equal EXPECTED[m][:present], EXPECTED[m][:h1_inside], m.to_s
      refute_equal EXPECTED[m][:present], EXPECTED[m][:followed_by_heading], m.to_s
    end
  end

  def test_cross_parser_autolinked_urls_never_unwrapped
    # FLAG: no parser unwraps Markdown autolinks "[url](url)"; the raw
    # bracket form flows into config. lingq image additionally prefixes the
    # podcast dir ("/pod/[https://...") and language drops a voice_id that
    # contains a colon ({"code" => "fr"}).
    assert_equal "/pod/[https://ex.com/i.png](https://ex.com/i.png)", EXPECTED[:parse_lingq_section][:autolinked_url].first[:image]
    assert_equal({"code" => "fr"}, EXPECTED[:parse_language_section][:autolinked_url].first.last)
    assert_equal "[https://ex.com/feed](https://ex.com/feed)", EXPECTED[:parse_sources_section][:autolinked_url].first["rss"].first[:url]
  end

  private

  def run_cell(method, shape)
    text = SHAPES.fetch(shape).call(*SPECS.fetch(method))
    parser = GuidelinesParser.new(text, podcast_dir: PODCAST_DIR)
    result =
      if method == :parse_kv_section
        parser.send(:parse_kv_section, SPECS[method][0]) { |k, v| {k => v} }
      else
        parser.send(method)
      end
    [result, parser.instance_variable_get(:@warnings)]
  end
end
