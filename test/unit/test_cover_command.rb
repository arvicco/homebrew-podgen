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

  def test_no_title_returns_usage
    _, err = capture_io do
      code = PodgenCLI::CoverCommand.new(["testpod"], {}).run
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
