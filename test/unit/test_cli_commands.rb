# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"

# Tests for CLI commands that previously lacked coverage:
# ListCommand, ScheduleCommand, RssCommand, SiteCommand.
class TestCLICommands < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_cli_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    @output_dir = File.join(@tmpdir, "output", "testpod")
    @episodes_dir = File.join(@output_dir, "episodes")
    FileUtils.mkdir_p(@podcast_dir)
    FileUtils.mkdir_p(@episodes_dir)
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # --- ListCommand ---

  def test_list_no_podcasts
    require "cli/list_command"
    FileUtils.rm_rf(File.join(@tmpdir, "podcasts", "testpod"))

    out, = capture_io do
      code = PodgenCLI::ListCommand.new([], {}).run
      assert_equal 0, code
    end

    assert_includes out, "No podcasts found"
  end

  def test_list_podcast_with_title
    require "cli/list_command"
    File.write(File.join(@podcast_dir, "guidelines.md"),
      "# Test\n## Podcast\nName: My Great Show\n## Format\nfoo\n## Tone\nbar")

    out, = capture_io do
      code = PodgenCLI::ListCommand.new([], {}).run
      assert_equal 0, code
    end

    assert_includes out, "Available podcasts:"
    assert_includes out, "testpod"
  end

  def test_list_podcast_missing_guidelines
    require "cli/list_command"
    # No guidelines.md in podcast_dir
    FileUtils.rm_f(File.join(@podcast_dir, "guidelines.md"))

    out, = capture_io do
      PodgenCLI::ListCommand.new([], {}).run
    end

    assert_includes out, "missing guidelines.md"
  end

  # --- ScheduleCommand ---

  def test_schedule_no_podcast_name
    require "cli/schedule_command"

    _, err = capture_io do
      code = PodgenCLI::ScheduleCommand.new([], {}).run
      assert_equal 2, code
    end

    assert_includes err, "Usage: podgen schedule"
  end

  # --- RssCommand ---

  def test_rss_no_podcast_name
    require "cli/rss_command"

    _, err = capture_io do
      code = PodgenCLI::RssCommand.new([], {}).run
      assert_equal 2, code
    end

    assert_includes err, "Usage: podgen rss"
  end

  def test_rss_base_url_option_parsing
    require "cli/rss_command"

    cmd = PodgenCLI::RssCommand.new(
      ["--base-url", "https://example.com/pod", "testpod"], {})

    assert_equal "https://example.com/pod", cmd.instance_variable_get(:@options)[:base_url]
    assert_equal "testpod", cmd.instance_variable_get(:@podcast_name)
  end

  # --- SiteCommand ---

  def test_site_no_podcast_name
    require "cli/site_command"

    _, err = capture_io do
      code = PodgenCLI::SiteCommand.new([], {}).run
      assert_equal 2, code
    end

    assert_includes err, "Usage: podgen site"
  end

  def test_site_option_parsing_clean
    require "cli/site_command"

    cmd = PodgenCLI::SiteCommand.new(["--clean", "testpod"], {})

    assert_equal true, cmd.instance_variable_get(:@clean)
    assert_equal "testpod", cmd.instance_variable_get(:@podcast_name)
  end

  def test_site_option_parsing_base_url
    require "cli/site_command"

    cmd = PodgenCLI::SiteCommand.new(
      ["--base-url", "https://example.com", "testpod"], {})

    assert_equal "https://example.com", cmd.instance_variable_get(:@base_url)
  end

  def test_site_default_options
    require "cli/site_command"

    cmd = PodgenCLI::SiteCommand.new(["testpod"], {})

    assert_equal false, cmd.instance_variable_get(:@clean)
    assert_nil cmd.instance_variable_get(:@base_url)
  end
end
