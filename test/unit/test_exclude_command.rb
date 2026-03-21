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
    FileUtils.mkdir_p(@podcast_dir)
    FileUtils.mkdir_p(@output_dir)
    File.write(File.join(@podcast_dir, "guidelines.md"), "# Test\n## Format\nfoo\n## Tone\nbar")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  def test_exclude_adds_urls_to_history
    out, = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a", "https://example.com/b"], {})
      code = cmd.run
      assert_equal 0, code
    end

    entries = YAML.load_file(@history_path)
    assert_equal 1, entries.length
    assert_equal ["https://example.com/a", "https://example.com/b"], entries.last["urls"]
    assert_includes out, "2 URL(s)"
  end

  def test_exclude_appends_to_existing_history
    File.write(@history_path, [{ "date" => "2026-01-01", "title" => "Old", "topics" => [], "urls" => ["https://old.com"] }].to_yaml)

    capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/new"], {})
      cmd.run
    end

    entries = YAML.load_file(@history_path)
    assert_equal 2, entries.length
    assert_equal ["https://old.com"], entries.first["urls"]
    assert_equal ["https://example.com/new"], entries.last["urls"]
  end

  def test_exclude_sets_date_to_today
    capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a"], {})
      cmd.run
    end

    entries = YAML.load_file(@history_path)
    assert_equal Date.today.to_s, entries.last["date"]
  end

  def test_exclude_marks_entry_as_excluded
    capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a"], {})
      cmd.run
    end

    entries = YAML.load_file(@history_path)
    assert_equal "(excluded)", entries.last["title"]
    assert_empty entries.last["topics"]
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
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a?utm_source=twitter&fbclid=abc"], {})
      cmd.run
    end

    entries = YAML.load_file(@history_path)
    assert_equal ["https://example.com/a"], entries.last["urls"]
  end

  def test_exclude_skips_duplicate_urls
    File.write(@history_path, [{ "date" => "2026-01-01", "title" => "Old", "topics" => [], "urls" => ["https://example.com/a"] }].to_yaml)

    out, = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a", "https://example.com/b"], {})
      cmd.run
    end

    entries = YAML.load_file(@history_path)
    # Only the new URL should be added
    assert_equal ["https://example.com/b"], entries.last["urls"]
    assert_includes out, "1 URL(s)"
    assert_includes out, "1 already excluded"
  end

  def test_exclude_all_duplicates_reports_nothing_to_add
    File.write(@history_path, [{ "date" => "2026-01-01", "title" => "Old", "topics" => [], "urls" => ["https://example.com/a"] }].to_yaml)

    out, = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a"], {})
      code = cmd.run
      assert_equal 0, code
    end

    assert_includes out, "already excluded"
    # Should not add an empty entry
    entries = YAML.load_file(@history_path)
    assert_equal 1, entries.length
  end
end
