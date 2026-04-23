# frozen_string_literal: true

require_relative "../test_helper"
require "guidelines_parser"

class TestGuidelinesParser < Minitest::Test
  def setup
    @podcast_dir = Dir.mktmpdir("podgen_gp_test")
  end

  def teardown
    FileUtils.rm_rf(@podcast_dir)
  end

  # --- extract_section via extract_heading ---

  def test_extract_heading_returns_first_line
    parser = build_parser("## Name\nMy Show\n\n## Format\nShort.")
    assert_equal "My Show", parser.extract_heading("Name")
  end

  def test_extract_heading_returns_nil_for_missing
    parser = build_parser("## Podcast\n- name: Test")
    assert_nil parser.extract_heading("Missing")
  end

  # --- HTML comment stripping ---

  def test_strips_html_comments
    parser = build_parser("## Podcast\n<!-- hidden -->\n- name: Visible\n")
    assert_equal "Visible", parser.podcast_section[:name]
  end

  # --- podcast_section ---

  def test_parses_podcast_name_and_author
    parser = build_parser(<<~MD)
      ## Podcast
      - name: My Show
      - author: Jane Doe
      - type: news
    MD

    assert_equal "My Show", parser.podcast_section[:name]
    assert_equal "Jane Doe", parser.podcast_section[:author]
    assert_equal "news", parser.podcast_section[:type]
  end

  def test_parses_languages_with_voice_ids
    parser = build_parser(<<~MD)
      ## Podcast
      - name: Test
      - language:
        - en: voice_en
        - es: voice_es
    MD

    langs = parser.podcast_section[:languages]
    assert_equal 2, langs.length
    assert_equal "en", langs[0]["code"]
    assert_equal "voice_en", langs[0]["voice_id"]
    assert_equal "es", langs[1]["code"]
  end

  def test_parses_languages_without_voice_ids
    parser = build_parser(<<~MD)
      ## Podcast
      - name: Test
      - language:
        - en
        - fr
    MD

    langs = parser.podcast_section[:languages]
    assert_equal 2, langs.length
    assert_equal "en", langs[0]["code"]
    assert_nil langs[0]["voice_id"]
  end

  def test_podcast_section_empty_when_missing
    parser = build_parser("## Format\nShort.\n")
    assert_equal({}, parser.podcast_section)
  end

  # --- audio_section ---

  def test_parses_audio_skip_and_cut
    parser = build_parser(<<~MD)
      ## Audio
      - skip: 30
      - cut: 1:20
    MD

    assert_equal 30.0, parser.audio_section[:skip]
    assert parser.audio_section[:cut].absolute?
  end

  def test_parses_audio_engines
    parser = build_parser(<<~MD)
      ## Audio
      - engine:
        - open
        - groq
    MD

    assert_equal %w[open groq], parser.audio_section[:engines]
  end

  def test_parses_audio_autotrim_bare
    parser = build_parser("## Audio\n- autotrim\n")
    assert_equal true, parser.audio_section[:autotrim]
  end

  def test_parses_audio_autotrim_with_colon
    parser = build_parser("## Audio\n- autotrim: true\n")
    assert_equal true, parser.audio_section[:autotrim]
  end

  def test_audio_section_empty_when_missing
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_equal({}, parser.audio_section)
  end

  # --- image_section ---

  def test_parses_image_section
    parser = build_parser(<<~MD)
      ## Image
      - cover: artwork.png
      - base_image: bg.png
      - font: Helvetica
      - font_size: 48
    MD

    assert_equal "artwork.png", parser.image_section[:cover]
    assert_equal File.join(@podcast_dir, "bg.png"), parser.image_section[:base_image]
    assert_equal "Helvetica", parser.image_section[:font]
    assert_equal 48, parser.image_section[:font_size]
  end

  def test_image_base_image_resolves_relative_path
    parser = build_parser("## Image\n- base_image: images/bg.png\n")
    assert_equal File.join(@podcast_dir, "images/bg.png"), parser.image_section[:base_image]
  end

  def test_image_base_image_keeps_absolute_path
    parser = build_parser("## Image\n- base_image: /absolute/bg.png\n")
    assert_equal "/absolute/bg.png", parser.image_section[:base_image]
  end

  def test_image_section_parses_all_fields
    parser = build_parser(<<~MD)
      ## Image
      - cover: artwork.png
      - image: ep.png
      - base_image: bg.png
      - font: Arial
      - font_color: #fff
      - font_size: 36
      - text_width: 400
      - text_gravity: north
      - text_x_offset: 10
      - text_y_offset: 20
    MD

    s = parser.image_section
    assert_equal "artwork.png", s[:cover]
    assert_equal "ep.png", s[:image]
    assert_equal File.join(@podcast_dir, "bg.png"), s[:base_image]
    assert_equal "Arial", s[:font]
    assert_equal "#fff", s[:font_color]
    assert_equal 36, s[:font_size]
    assert_equal 400, s[:text_width]
    assert_equal "north", s[:text_gravity]
    assert_equal 10, s[:text_x_offset]
    assert_equal 20, s[:text_y_offset]
  end

  def test_image_section_empty_when_missing
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_equal({}, parser.image_section)
  end

  # --- site_config ---

  def test_parses_site_section
    parser = build_parser(<<~MD)
      ## Site
      - accent: #ff6600
      - radius: 8px
      - footer: My Footer
      - show_duration: false
    MD

    assert_equal "#ff6600", parser.site_config[:accent]
    assert_equal "8px", parser.site_config[:radius]
    assert_equal "My Footer", parser.site_config[:footer]
    assert_equal false, parser.site_config[:show_duration]
  end

  def test_site_hex_color_with_inline_comment
    parser = build_parser("## Site\n- accent: #e11d48  # rose red\n")
    assert_equal "#e11d48", parser.site_config[:accent]
  end

  def test_site_sanitizes_css
    parser = build_parser("## Site\n- accent: red;}\n")
    assert_equal "red", parser.site_config[:accent]
  end

  def test_site_section_parses_all_fields
    parser = build_parser(<<~MD)
      ## Site
      - accent: #ff0000
      - accent_dark: #cc0000
      - bg: #ffffff
      - bg_dark: #000000
      - radius: 4px
      - max_width: 800px
      - footer: Copyright 2025
      - show_duration: true
      - show_transcript: false
    MD

    s = parser.site_config
    assert_equal "#ff0000", s[:accent]
    assert_equal "#cc0000", s[:accent_dark]
    assert_equal "#ffffff", s[:bg]
    assert_equal "#000000", s[:bg_dark]
    assert_equal "4px", s[:radius]
    assert_equal "800px", s[:max_width]
    assert_equal "Copyright 2025", s[:footer]
    assert_equal true, s[:show_duration]
    assert_equal false, s[:show_transcript]
  end

  def test_site_config_empty_when_missing
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_equal({}, parser.site_config)
  end

  # --- sources ---

  def test_parses_sources_simple
    parser = build_parser(<<~MD)
      ## Sources
      - exa
      - hackernews
    MD

    assert_equal true, parser.sources["exa"]
    assert_equal true, parser.sources["hackernews"]
  end

  def test_parses_sources_with_rss_list
    parser = build_parser(<<~MD)
      ## Sources
      - rss:
        - https://example.com/feed
        - https://other.com/feed
    MD

    assert_equal 2, parser.sources["rss"].length
    assert_equal "https://example.com/feed", parser.sources["rss"][0]
  end

  def test_parses_rss_with_inline_options
    parser = build_parser(<<~MD)
      ## Sources
      - rss:
        - https://example.com/feed skip: 30 cut: 10
    MD

    entry = parser.sources["rss"][0]
    assert_equal "https://example.com/feed", entry[:url]
    assert_equal 30.0, entry[:skip]
    assert_equal 10.0, entry[:cut]
  end

  def test_parses_rss_with_autotrim_flag
    parser = build_parser(<<~MD)
      ## Sources
      - rss:
        - https://example.com/feed autotrim
    MD

    entry = parser.sources["rss"][0]
    assert_equal true, entry[:autotrim]
  end

  def test_parses_rss_with_tag
    parser = build_parser(<<~MD)
      ## Sources
      - rss:
        - https://anchor.fm/s/7ad18ac4/podcast/rss tag: babi skip: 30
    MD

    entry = parser.sources["rss"][0]
    assert_equal "https://anchor.fm/s/7ad18ac4/podcast/rss", entry[:url]
    assert_equal "babi", entry[:tag]
    assert_equal 30.0, entry[:skip]
  end

  def test_parses_rss_with_weight
    parser = build_parser(<<~MD)
      ## Sources
      - rss:
        - https://example.com/feed1 tag: alpha weight: 40
        - https://example.com/feed2 tag: beta weight: 20
    MD

    entries = parser.sources["rss"]
    assert_equal 40, entries[0][:weight]
    assert_equal 20, entries[1][:weight]
  end

  def test_parses_select_mode
    parser = build_parser(<<~MD)
      ## Sources
      - select: weights
      - rss:
        - https://example.com/feed
    MD

    assert_equal ["weights"], parser.sources["select"]
  end

  def test_parses_select_mode_strips_inline_comment
    parser = build_parser(<<~MD)
      ## Sources
      - select: weights # latest (default) | cycle | weights
      - rss:
        - https://example.com/feed
    MD

    assert_equal ["weights"], parser.sources["select"]
  end

  def test_inline_comment_does_not_strip_url_fragments
    parser = build_parser(<<~MD)
      ## Sources
      - rss:
        - https://example.com/feed#section
    MD

    assert_equal "https://example.com/feed#section", parser.sources["rss"][0]
  end

  def test_sources_defaults_to_exa
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_equal({ "exa" => true }, parser.sources)
  end

  # --- lingq_config ---

  def test_parses_lingq_section
    parser = build_parser(<<~MD)
      ## LingQ
      - collection: 12345
      - level: 3
      - tags: podcast, ruby
    MD

    assert_equal 12345, parser.lingq_config[:collection]
    assert_equal 3, parser.lingq_config[:level]
    assert_equal %w[podcast ruby], parser.lingq_config[:tags]
  end

  def test_parses_lingq_token
    parser = build_parser(<<~MD)
      ## LingQ
      - collection: 12345
      - token: sk-test-key-123
    MD

    assert_equal "sk-test-key-123", parser.lingq_config[:token]
    assert_equal 12345, parser.lingq_config[:collection]
  end

  def test_lingq_config_nil_when_missing
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_nil parser.lingq_config
  end

  def test_lingq_config_parses_image_and_style_fields
    parser = build_parser(<<~MD)
      ## LingQ
      - collection: 999
      - image: cover.png
      - base_image: bg.png
      - font: Arial
      - font_color: white
      - font_size: 24
      - text_width: 300
      - text_gravity: center
      - text_x_offset: 5
      - text_y_offset: 10
      - accent: blue
      - status: private
    MD

    c = parser.lingq_config
    assert_equal 999, c[:collection]
    assert_equal File.join(@podcast_dir, "cover.png"), c[:image]
    assert_equal File.join(@podcast_dir, "bg.png"), c[:base_image]
    assert_equal "Arial", c[:font]
    assert_equal "white", c[:font_color]
    assert_equal 24, c[:font_size]
    assert_equal 300, c[:text_width]
    assert_equal "center", c[:text_gravity]
    assert_equal 5, c[:text_x_offset]
    assert_equal 10, c[:text_y_offset]
    assert_equal "blue", c[:accent]
    assert_equal "private", c[:status]
  end

  # --- youtube_config ---

  def test_parses_youtube_section
    parser = build_parser(<<~MD)
      ## YouTube
      - playlist: PLxxxxxxxxx
      - privacy: unlisted
      - category: 27
      - tags: podcast, slovenian, language learning
    MD
    assert_equal "PLxxxxxxxxx", parser.youtube_config[:playlist]
    assert_equal "unlisted", parser.youtube_config[:privacy]
    assert_equal "27", parser.youtube_config[:category]
    assert_equal ["podcast", "slovenian", "language learning"], parser.youtube_config[:tags]
  end

  def test_youtube_config_nil_when_missing
    parser = build_parser("## Podcast\n- name: Test")
    assert_nil parser.youtube_config
  end

  def test_youtube_config_rejects_invalid_privacy
    parser = build_parser("## YouTube\n- privacy: secret\n- playlist: PLabc")
    assert_equal "PLabc", parser.youtube_config[:playlist]
    refute parser.youtube_config.key?(:privacy)
  end

  # --- languages ---

  def test_languages_from_podcast_section
    parser = build_parser(<<~MD)
      ## Podcast
      - name: Test
      - language:
        - en
        - es
    MD

    assert_equal 2, parser.languages.length
    assert_equal "en", parser.languages[0]["code"]
  end

  def test_languages_from_legacy_section
    parser = build_parser(<<~MD)
      ## Podcast
      - name: Test

      ## Language
      - en
      - fr
    MD

    assert_equal 2, parser.languages.length
    assert_equal "fr", parser.languages[1]["code"]
  end

  def test_languages_defaults_to_english
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_equal [{ "code" => "en" }], parser.languages
  end

  # --- transcription_engines ---

  def test_engines_from_audio_section
    parser = build_parser(<<~MD)
      ## Audio
      - engine:
        - open
        - elab
        - groq
    MD

    assert_equal %w[open elab groq], parser.transcription_engines
  end

  def test_engines_from_legacy_section
    parser = build_parser(<<~MD)
      ## Transcription Engine
      - groq
      - open
    MD

    assert_equal %w[groq open], parser.transcription_engines
  end

  def test_engines_defaults_to_open
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_equal ["open"], parser.transcription_engines
  end

  # --- links_config ---

  def test_parses_links_section
    parser = build_parser(<<~MD)
      ## Links
      - show: true
    MD

    assert_equal({ show: true }, parser.links_config)
  end

  def test_links_config_nil_when_show_false
    parser = build_parser(<<~MD)
      ## Links
      - show: false
    MD

    assert_nil parser.links_config
  end

  def test_parses_links_position_bottom
    parser = build_parser("## Links\n- show: true\n- position: bottom\n")
    assert_equal "bottom", parser.links_config[:position]
  end

  def test_parses_links_position_inline
    parser = build_parser("## Links\n- show: true\n- position: inline\n")
    assert_equal "inline", parser.links_config[:position]
  end

  def test_parses_links_position_inline_with_comment
    parser = build_parser("## Links\n- show: true\n- position: inline    # bottom or inline\n")
    assert_equal "inline", parser.links_config[:position]
  end

  def test_parses_links_invalid_position_ignored
    parser = build_parser("## Links\n- show: true\n- position: scattered\n")
    refute parser.links_config.key?(:position)
  end

  def test_parses_links_title
    parser = build_parser("## Links\n- show: true\n- title: Read more\n")
    assert_equal "Read more", parser.links_config[:title]
  end

  def test_parses_links_max
    parser = build_parser("## Links\n- show: true\n- max: 5\n")
    assert_equal 5, parser.links_config[:max]
  end

  def test_parses_links_max_zero_ignored
    parser = build_parser("## Links\n- show: true\n- max: 0\n")
    refute parser.links_config.key?(:max)
  end

  def test_parses_links_full_config
    parser = build_parser(<<~MD)
      ## Links
      - show: true
      - position: inline
      - title: Sources
      - max: 3
    MD

    c = parser.links_config
    assert_equal true, c[:show]
    assert_equal "inline", c[:position]
    assert_equal "Sources", c[:title]
    assert_equal 3, c[:max]
  end

  def test_links_config_nil_when_missing
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_nil parser.links_config
  end

  # --- vocabulary_config ---

  def test_parses_vocabulary_level
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: B1
    MD

    assert_equal({ level: "B1" }, parser.vocabulary_config)
  end

  def test_parses_vocabulary_level_case_insensitive
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: b2
    MD

    assert_equal({ level: "B2" }, parser.vocabulary_config)
  end

  def test_vocabulary_config_nil_when_missing
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_nil parser.vocabulary_config
  end

  def test_vocabulary_config_nil_when_empty
    parser = build_parser("## Vocabulary\n\n## Podcast\n- name: Test\n")
    assert_nil parser.vocabulary_config
  end

  def test_vocabulary_rejects_invalid_level
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: X1
    MD

    assert_nil parser.vocabulary_config
  end

  def test_parses_vocabulary_full_config
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: B2
      - max: 15
      - frequency: rare
      - similar: Russian
      - filter: Skip animal names
    MD

    config = parser.vocabulary_config
    assert_equal "B2", config[:level]
    assert_equal 15, config[:max]
    assert_equal "rare", config[:frequency]
    assert_equal "Russian", config[:similar]
    assert_equal "Skip animal names", config[:filter]
  end

  def test_vocabulary_max_rejects_zero
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: B2
      - max: 0
    MD

    refute parser.vocabulary_config.key?(:max)
  end

  def test_vocabulary_frequency_rejects_invalid
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: B2
      - frequency: sometimes
    MD

    refute parser.vocabulary_config.key?(:frequency)
  end

  def test_parses_vocabulary_target_language
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: B2
      - target: Polish
    MD

    assert_equal "Polish", parser.vocabulary_config[:target]
  end

  def test_parses_vocabulary_priority
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: B2
      - priority: frequent
    MD

    assert_equal "frequent", parser.vocabulary_config[:priority]
  end

  def test_vocabulary_priority_rejects_invalid
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: B2
      - priority: random
    MD

    refute parser.vocabulary_config.key?(:priority)
  end

  def test_vocabulary_target_defaults_to_nil_when_missing
    parser = build_parser(<<~MD)
      ## Vocabulary
      - level: B2
    MD

    assert_nil parser.vocabulary_config[:target]
  end

  # --- text accessor ---

  def test_text_returns_comment_stripped_guidelines
    parser = build_parser("## Podcast\n<!-- comment -->\n- name: Test\n")
    refute_includes parser.text, "<!-- comment -->"
    assert_includes parser.text, "- name: Test"
  end

  private

  def build_parser(text)
    GuidelinesParser.new(text, podcast_dir: @podcast_dir)
  end
end
