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

  def test_site_sanitizes_css
    parser = build_parser("## Site\n- accent: red;}\n")
    assert_equal "red", parser.site_config[:accent]
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

  def test_lingq_config_nil_when_missing
    parser = build_parser("## Podcast\n- name: Test\n")
    assert_nil parser.lingq_config
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
