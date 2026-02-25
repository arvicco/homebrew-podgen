# frozen_string_literal: true

require_relative "../test_helper"
require "podcast_config"

class TestPodcastConfig < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_test")
    @podcasts_dir = File.join(@tmpdir, "podcasts", "myshow")
    @output_dir = File.join(@tmpdir, "output", "myshow")
    FileUtils.mkdir_p(@podcasts_dir)
    FileUtils.mkdir_p(File.join(@output_dir, "episodes"))
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # --- ## Podcast section (new consolidated format) ---

  def test_parses_podcast_section_name
    write_guidelines(<<~MD)
      ## Podcast
      - name: My Great Show
      - author: Jane Doe

      ## Format
      Short episodes.

      ## Tone
      Casual.

      ## Topics
      - Tech
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "My Great Show", config.title
    assert_equal "Jane Doe", config.author
  end

  def test_parses_podcast_section_type
    write_guidelines(<<~MD)
      ## Podcast
      - name: Lang Show
      - type: language

      ## Format
      Source audio.

      ## Tone
      Educational.
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "language", config.type
  end

  def test_parses_base_url_and_image
    write_guidelines(<<~MD)
      ## Podcast
      - name: Show
      - base_url: https://example.com/show
      - image: cover.jpg

      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "https://example.com/show", config.base_url
    assert_equal "cover.jpg", config.image
  end

  def test_parses_languages_with_voice_ids
    write_guidelines(<<~MD)
      ## Podcast
      - name: Multi Show
      - language:
        - en
        - es: voice_es_123
        - fr: voice_fr_456

      ## Format
      Two segments.

      ## Tone
      Friendly.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    langs = config.languages
    assert_equal 3, langs.length
    assert_equal({ "code" => "en" }, langs[0])
    assert_equal({ "code" => "es", "voice_id" => "voice_es_123" }, langs[1])
    assert_equal({ "code" => "fr", "voice_id" => "voice_fr_456" }, langs[2])
  end

  def test_defaults_when_podcast_section_missing
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "myshow", config.title  # falls back to dir name
    assert_equal "Podcast Agent", config.author
    assert_equal "news", config.type
    assert_nil config.base_url
    assert_nil config.image
    assert_equal [{ "code" => "en" }], config.languages
  end

  # --- ## Sources section ---

  def test_parses_flat_sources
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - exa
      - hackernews
    MD

    config = PodcastConfig.new("myshow")
    assert_equal({ "exa" => true, "hackernews" => true }, config.sources)
  end

  def test_parses_sources_with_nested_urls
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - rss:
        - https://example.com/feed1.xml
        - https://example.com/feed2.xml
      - hackernews
    MD

    config = PodcastConfig.new("myshow")
    expected = {
      "rss" => ["https://example.com/feed1.xml", "https://example.com/feed2.xml"],
      "hackernews" => true
    }
    assert_equal expected, config.sources
  end

  def test_parses_inline_comma_sources
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Sources
      - x: @user1, @user2
    MD

    config = PodcastConfig.new("myshow")
    assert_equal({ "x" => ["@user1", "@user2"] }, config.sources)
  end

  def test_defaults_to_exa_when_sources_missing
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal({ "exa" => true }, config.sources)
  end

  # --- ## Audio section ---

  def test_parses_audio_engines
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Audio
      - engine:
        - open
        - groq
      - language: sl
      - target_language: Slovenian
      - skip_intro: 30.5
    MD

    config = PodcastConfig.new("myshow")
    assert_equal ["open", "groq"], config.transcription_engines
    assert_equal "sl", config.transcription_language
    assert_equal "Slovenian", config.target_language
    assert_in_delta 30.5, config.skip_intro
  end

  def test_audio_defaults
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal ["open"], config.transcription_engines
    assert_nil config.transcription_language
    assert_nil config.target_language
    assert_nil config.skip_intro
  end

  # --- Legacy format fallback ---

  def test_legacy_name_and_type_sections
    write_guidelines(<<~MD)
      ## Name
      Legacy Show

      ## Type
      language

      ## Format
      Source audio.

      ## Tone
      Clear.
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "Legacy Show", config.title
    assert_equal "language", config.type
  end

  def test_legacy_language_section
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News

      ## Language
      - en
      - it: voice_it_789
    MD

    config = PodcastConfig.new("myshow")
    langs = config.languages
    assert_equal 2, langs.length
    assert_equal({ "code" => "en" }, langs[0])
    assert_equal({ "code" => "it", "voice_id" => "voice_it_789" }, langs[1])
  end

  def test_legacy_transcription_engine_section
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Transcription Engine
      - open
      - elab
    MD

    config = PodcastConfig.new("myshow")
    assert_equal ["open", "elab"], config.transcription_engines
  end

  # --- episode_basename ---

  def test_episode_basename_first_run
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_equal "myshow-2026-03-01", config.episode_basename(Date.new(2026, 3, 1))
  end

  def test_episode_basename_suffix_generation
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    # Create a fake first episode MP3
    eps_dir = File.join(@output_dir, "episodes")
    File.write(File.join(eps_dir, "myshow-2026-03-01.mp3"), "x")

    config = PodcastConfig.new("myshow")
    assert_equal "myshow-2026-03-01a", config.episode_basename(Date.new(2026, 3, 1))
  end

  def test_episode_basename_ignores_language_suffixed_files
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    eps_dir = File.join(@output_dir, "episodes")
    File.write(File.join(eps_dir, "myshow-2026-03-01.mp3"), "x")
    File.write(File.join(eps_dir, "myshow-2026-03-01-es.mp3"), "x")
    File.write(File.join(eps_dir, "myshow-2026-03-01-fr.mp3"), "x")

    config = PodcastConfig.new("myshow")
    # Only the base mp3 counts, not the language-suffixed ones
    assert_equal "myshow-2026-03-01a", config.episode_basename(Date.new(2026, 3, 1))
  end

  # --- LingQ section ---

  def test_parses_lingq_section
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## LingQ
      - collection: 12345
      - level: 3
      - tags: podcast, slovenian
      - accent: sl-SI
      - status: new
    MD

    config = PodcastConfig.new("myshow")
    lc = config.lingq_config
    refute_nil lc
    assert_equal 12345, lc[:collection]
    assert_equal 3, lc[:level]
    assert_equal ["podcast", "slovenian"], lc[:tags]
    assert_equal "sl-SI", lc[:accent]
    assert_equal "new", lc[:status]
  end

  def test_lingq_nil_when_section_missing
    write_guidelines(<<~MD)
      ## Format
      Short.

      ## Tone
      Fun.

      ## Topics
      - News
    MD

    config = PodcastConfig.new("myshow")
    assert_nil config.lingq_config
  end

  private

  def write_guidelines(content)
    File.write(File.join(@podcasts_dir, "guidelines.md"), content)
  end
end
