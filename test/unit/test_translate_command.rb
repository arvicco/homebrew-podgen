# frozen_string_literal: true

require_relative "../test_helper"
require "cli/translate_command"

class TestTranslateCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_translate_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- discover_episodes ---

  def test_discover_episodes_finds_english_scripts_with_mp3
    create_script("mypod-2026-01-15_script.md", "# Title\n\n## Opening\n\nHello.")
    create_mp3("mypod-2026-01-15.mp3")

    cmd = build_command
    episodes = cmd.send(:discover_episodes, @episodes_dir)

    assert_equal 1, episodes.length
    assert_equal "mypod-2026-01-15", episodes.first[:basename]
  end

  def test_discover_episodes_excludes_language_suffixed_scripts
    create_script("mypod-2026-01-15_script.md", "# English")
    create_script("mypod-2026-01-15-es_script.md", "# Spanish")
    create_mp3("mypod-2026-01-15.mp3")

    cmd = build_command
    episodes = cmd.send(:discover_episodes, @episodes_dir)

    assert_equal 1, episodes.length
    assert_equal "mypod-2026-01-15", episodes.first[:basename]
  end

  def test_discover_episodes_excludes_orphaned_scripts
    create_script("mypod-2026-01-15_script.md", "# Title")
    # No matching MP3

    cmd = build_command
    episodes = cmd.send(:discover_episodes, @episodes_dir)

    assert_empty episodes
  end

  def test_discover_episodes_sorted_chronologically
    create_script("mypod-2026-01-15_script.md", "# A")
    create_script("mypod-2026-01-16_script.md", "# B")
    create_mp3("mypod-2026-01-15.mp3")
    create_mp3("mypod-2026-01-16.mp3")

    cmd = build_command
    episodes = cmd.send(:discover_episodes, @episodes_dir)

    assert_equal "mypod-2026-01-15", episodes.first[:basename]
    assert_equal "mypod-2026-01-16", episodes.last[:basename]
  end

  # --- pending_translations ---

  def test_pending_translations_finds_missing_mp3s
    episodes = [{ script_path: "/path/a_script.md", basename: "a" }]
    languages = [{ "code" => "es", "voice_id" => "voice1" }]

    cmd = build_command
    pending = cmd.send(:pending_translations, episodes, languages, @episodes_dir)

    assert_equal 1, pending.length
    assert_equal "es", pending.first[:lang_code]
    assert_equal "voice1", pending.first[:voice_id]
  end

  def test_pending_translations_skips_existing_mp3s
    create_mp3("a-es.mp3")
    episodes = [{ script_path: "/path/a_script.md", basename: "a" }]
    languages = [{ "code" => "es", "voice_id" => nil }]

    cmd = build_command
    pending = cmd.send(:pending_translations, episodes, languages, @episodes_dir)

    assert_empty pending
  end

  def test_pending_translations_multiple_languages
    episodes = [{ script_path: "/path/a_script.md", basename: "a" }]
    languages = [
      { "code" => "es", "voice_id" => nil },
      { "code" => "fr", "voice_id" => nil }
    ]

    cmd = build_command
    pending = cmd.send(:pending_translations, episodes, languages, @episodes_dir)

    assert_equal 2, pending.length
    codes = pending.map { |p| p[:lang_code] }
    assert_includes codes, "es"
    assert_includes codes, "fr"
  end

  # --- parse_script / save_script roundtrip ---

  def test_parse_script_extracts_title_and_segments
    path = create_script("test_script.md", <<~MD)
      # My Title

      ## Opening

      Welcome to the show.

      ## Main Topic

      Here is the content.
    MD

    cmd = build_command
    script = cmd.send(:parse_script, path)

    assert_equal "My Title", script[:title]
    assert_equal 2, script[:segments].length
    assert_equal "Opening", script[:segments].first[:name]
    assert_equal "Welcome to the show.", script[:segments].first[:text]
  end

  def test_save_script_writes_markdown
    cmd = build_command
    script = {
      title: "Translated Title",
      segments: [
        { name: "Apertura", text: "Bienvenidos." },
        { name: "Tema", text: "Contenido aquí." }
      ]
    }
    path = File.join(@episodes_dir, "output_script.md")
    cmd.send(:save_script, script, path)

    content = File.read(path)
    assert_includes content, "# Translated Title"
    assert_includes content, "## Apertura"
    assert_includes content, "Bienvenidos."
  end

  def test_parse_save_roundtrip
    original = {
      title: "Round Trip",
      segments: [
        { name: "Section One", text: "First text." },
        { name: "Section Two", text: "Second text." }
      ]
    }

    path = File.join(@episodes_dir, "roundtrip.md")
    cmd = build_command
    cmd.send(:save_script, original, path)
    parsed = cmd.send(:parse_script, path)

    assert_equal original[:title], parsed[:title]
    assert_equal original[:segments].length, parsed[:segments].length
    assert_equal "Section One", parsed[:segments].first[:name]
    assert_equal "First text.", parsed[:segments].first[:text]
  end

  private

  def create_script(name, content)
    path = File.join(@episodes_dir, name)
    File.write(path, content)
    path
  end

  def create_mp3(name)
    File.write(File.join(@episodes_dir, name), "x" * 1000)
  end

  def build_command
    PodgenCLI::TranslateCommand.allocate
  end
end
