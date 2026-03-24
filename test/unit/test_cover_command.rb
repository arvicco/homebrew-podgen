# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "cli/cover_command"

class TestCoverCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_cover_cmd_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    FileUtils.mkdir_p(@podcast_dir)
    File.write(File.join(@podcast_dir, "guidelines.md"),
      "# Test\n## Podcast\nName: Test Pod\n## Format\nfoo\n## Tone\nbar\n## Image\n- base_image: base.png")
    File.write(File.join(@podcast_dir, "base.png"), "fake image")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  def test_no_podcast_returns_usage
    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new([], {}).run
      assert_equal 2, code
    end
    assert_includes err, "Usage:"
  end

  def test_missing_base_image_returns_error
    File.write(File.join(@podcast_dir, "guidelines.md"),
      "# Test\n## Podcast\nName: Test Pod\n## Format\nfoo\n## Tone\nbar")

    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod", "My Title"], {}).run
      assert_equal 1, code
    end
    assert_includes err, "base_image"
  end

  def test_option_parsing_base_image
    cmd = PodgenCLI::CoverCommand.new(
      ["--base-image", "/tmp/custom.png", "testpod", "My Title"], {})
    assert_equal "/tmp/custom.png", cmd.instance_variable_get(:@overrides)[:base_image]
  end

  def test_option_parsing_font_overrides
    cmd = PodgenCLI::CoverCommand.new(
      ["--font", "Arial", "--font-color", "#FF0000", "--font-size", "80",
       "testpod", "My Title"], {})
    overrides = cmd.instance_variable_get(:@overrides)
    assert_equal "Arial", overrides[:font]
    assert_equal "#FF0000", overrides[:font_color]
    assert_equal 80, overrides[:font_size]
  end

  def test_option_parsing_geometry
    cmd = PodgenCLI::CoverCommand.new(
      ["--gravity", "South", "--x-offset", "50", "--y-offset", "100",
       "testpod", "Title"], {})
    overrides = cmd.instance_variable_get(:@overrides)
    assert_equal "South", overrides[:gravity]
    assert_equal 50, overrides[:x_offset]
    assert_equal 100, overrides[:y_offset]
  end

  def test_option_parsing_output
    cmd = PodgenCLI::CoverCommand.new(
      ["--output", "/tmp/out.jpg", "testpod", "Title"], {})
    assert_equal "/tmp/out.jpg", cmd.instance_variable_get(:@output_path)
  end

  # --- --episode mode ---

  def test_episode_flag_extracts_title_from_transcript
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# My Episode Title\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["testpod", "2026-03-10"], {})
    assert_equal "2026-03-10", cmd.instance_variable_get(:@episode_id)
    assert_nil cmd.instance_variable_get(:@title)
  end

  def test_episode_resolves_title_and_output_path
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Medved z Nanosa\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["testpod", "2026-03-10"], {})
    config = Struct.new(:episodes_dir).new(episodes_dir)

    episodes = cmd.send(:resolve_episodes, config)
    assert_equal 1, episodes.length
    assert_equal "Medved z Nanosa", episodes[0][:title]
    assert_includes episodes[0][:output], "testpod-2026-03-10_cover.jpg"
  end

  def test_episode_not_found_returns_error
    cmd = PodgenCLI::CoverCommand.new(["testpod", "2026-99-99"], {})

    _, err = capture_io { code = cmd.run; assert_equal 1, code }
    assert_includes err, "No episodes found"
  end

  # --- batch mode ---

  def test_batch_mode_resolves_all_transcripts
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep One\n\n## Transcript\n\nText.")
    File.write(File.join(episodes_dir, "testpod-2026-03-11_transcript.md"), "# Ep Two\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["testpod"], {})
    config = Struct.new(:episodes_dir).new(episodes_dir)

    episodes = cmd.send(:resolve_episodes, config)
    assert_equal 2, episodes.length
  end

  def test_batch_mode_single_episode
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep One\n\n## Transcript\n\nText.")
    File.write(File.join(episodes_dir, "testpod-2026-03-11_transcript.md"), "# Ep Two\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["testpod", "2026-03-10"], {})
    config = Struct.new(:episodes_dir).new(episodes_dir)

    episodes = cmd.send(:resolve_episodes, config)
    assert_equal 1, episodes.length
    assert_equal "Ep One", episodes[0][:title]
  end

  def test_missing_only_skips_episodes_with_covers
    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep One\n\n## Transcript\n\nText.")
    File.write(File.join(episodes_dir, "testpod-2026-03-10_cover.jpg"), "fake")
    File.write(File.join(episodes_dir, "testpod-2026-03-11_transcript.md"), "# Ep Two\n\n## Transcript\n\nText.")

    cmd = PodgenCLI::CoverCommand.new(["--missing-only", "testpod"], {})
    config = Struct.new(:episodes_dir).new(episodes_dir)

    episodes = cmd.send(:resolve_episodes, config)
    assert_equal 1, episodes.length
    assert_equal "Ep Two", episodes[0][:title]
  end

  def test_dry_run_does_not_create_covers
    skip_unless_command("magick")
    skip_unless_command("rsvg-convert")

    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Ep One\n\n## Transcript\n\nText.")
    system("magick", "-size", "100x100", "xc:white", File.join(@podcast_dir, "base.png"))

    out, = capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod"], { dry_run: true }).run
      assert_equal 0, code
    end

    refute File.exist?(File.join(episodes_dir, "testpod-2026-03-10_cover.jpg"))
    assert_includes out, "dry-run"
  end

  def test_episode_generates_cover
    skip_unless_command("magick")
    skip_unless_command("rsvg-convert")

    episodes_dir = File.join(@tmpdir, "output", "testpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "testpod-2026-03-10_transcript.md"), "# Test Title\n\n## Transcript\n\nText.")

    # Create a real base image
    system("magick", "-size", "100x100", "xc:white", File.join(@podcast_dir, "base.png"))

    out, = capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod", "2026-03-10"], {}).run
      assert_equal 0, code
    end

    cover = File.join(episodes_dir, "testpod-2026-03-10_cover.jpg")
    assert File.exist?(cover)
    assert File.size(cover) > 0
  end

  def test_generates_cover_with_agent
    skip_unless_command("magick")
    skip_unless_command("rsvg-convert")

    output = File.join(@tmpdir, "cover_out.jpg")

    # Create a real 100x100 base image
    system("magick", "-size", "100x100", "xc:white", File.join(@podcast_dir, "base.png"))

    out, = capture_io do
      code = PodgenCLI::CoverCommand.new(
        ["--output", output, "testpod", "Test Title"], {}).run
      assert_equal 0, code
    end

    assert File.exist?(output)
    assert File.size(output) > 0
    assert_includes out, output
  end
end
