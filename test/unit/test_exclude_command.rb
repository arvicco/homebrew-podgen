# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "cli/exclude_command"

class TestExcludeCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_exclude_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    @output_dir = File.join(@tmpdir, "output", "testpod")
    @history_path = File.join(@output_dir, "history.yml")
    @excluded_path = File.join(@output_dir, "excluded_urls.yml")
    FileUtils.mkdir_p(@podcast_dir)
    FileUtils.mkdir_p(@output_dir)
    File.write(File.join(@podcast_dir, "guidelines.md"), "# Test\n## Format\nfoo\n## Tone\nbar")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  def test_exclude_writes_to_excluded_urls_file
    out, = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a", "https://example.com/b"], {})
      code = cmd.run
      assert_equal 0, code
    end

    assert File.exist?(@excluded_path)
    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://example.com/a", "https://example.com/b"], urls
    assert_includes out, "2 URL(s)"
  end

  def test_exclude_does_not_write_to_history
    capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a"], {}).run
    end

    refute File.exist?(@history_path)
  end

  def test_exclude_appends_to_existing_excluded_file
    File.write(@excluded_path, ["https://old.com"].to_yaml)

    capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/new"], {}).run
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://old.com", "https://example.com/new"], urls
  end

  def test_exclude_no_urls_returns_usage_error
    _, err = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod"], {})
      code = cmd.run
      assert_equal 2, code
    end

    assert_includes err, "Usage:"
  end

  def test_exclude_no_podcast_returns_usage_error
    _, err = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new([], {})
      code = cmd.run
      assert_equal 2, code
    end

    assert_includes err, "Usage:"
  end

  def test_exclude_strips_tracking_params
    capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a?utm_source=twitter&fbclid=abc"], {}).run
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://example.com/a"], urls
  end

  def test_exclude_skips_urls_already_in_excluded_file
    File.write(@excluded_path, ["https://example.com/a"].to_yaml)

    out, = capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a", "https://example.com/b"], {}).run
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://example.com/a", "https://example.com/b"], urls
    assert_includes out, "1 URL(s)"
    assert_includes out, "1 already excluded"
  end

  def test_exclude_skips_urls_already_in_history
    File.write(@history_path, [{ "date" => "2026-01-01", "title" => "Ep", "topics" => [], "urls" => ["https://example.com/a"] }].to_yaml)

    out, = capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a", "https://example.com/b"], {}).run
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://example.com/b"], urls
    assert_includes out, "1 already excluded"
  end

  def test_exclude_all_duplicates_reports_nothing_to_add
    File.write(@excluded_path, ["https://example.com/a"].to_yaml)

    out, = capture_io do
      code = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a"], {}).run
      assert_equal 0, code
    end

    assert_includes out, "already excluded"
  end
end
