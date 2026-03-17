# frozen_string_literal: true

require_relative "../test_helper"
require "priority_links"

# Tests for the add and links CLI commands.
# Tests the command classes directly, bypassing the CLI dispatcher.

ENV["ANTHROPIC_API_KEY"] ||= "test-key"

class TestAddLinksCommands < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_add_links_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "test_pod")
    FileUtils.mkdir_p(@podcast_dir)
    File.write(File.join(@podcast_dir, "guidelines.md"), "# Test\n## Podcast\nName: Test Pod\n")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # --- AddCommand ---

  def test_add_command_adds_link
    require "cli/add_command"

    out, = capture_io do
      cmd = PodgenCLI::AddCommand.new(["test_pod", "https://example.com/article"], {})
      code = cmd.run
      assert_equal 0, code
    end

    assert_includes out, "Added to test_pod"
    assert_includes out, "1 link(s) queued"

    # Verify file was created
    links = PriorityLinks.new(File.join(@podcast_dir, "links.yml"))
    assert_equal 1, links.count
    assert_equal "https://example.com/article", links.all.first["url"]
  end

  def test_add_command_with_note
    require "cli/add_command"

    capture_io do
      cmd = PodgenCLI::AddCommand.new(["test_pod", "https://example.com/article", "--note", "Great read"], {})
      cmd.run
    end

    links = PriorityLinks.new(File.join(@podcast_dir, "links.yml"))
    assert_equal "Great read", links.all.first["note"]
  end

  def test_add_command_strips_tracking_params
    require "cli/add_command"

    capture_io do
      cmd = PodgenCLI::AddCommand.new(["test_pod", "https://example.com/article?utm_source=twitter&fbclid=abc123"], {})
      cmd.run
    end

    links = PriorityLinks.new(File.join(@podcast_dir, "links.yml"))
    assert_equal "https://example.com/article", links.all.first["url"]
  end

  def test_add_command_detects_duplicate
    require "cli/add_command"

    links = PriorityLinks.new(File.join(@podcast_dir, "links.yml"))
    links.add("https://example.com/article")

    out, = capture_io do
      cmd = PodgenCLI::AddCommand.new(["test_pod", "https://example.com/article"], {})
      code = cmd.run
      assert_equal 0, code
    end

    assert_includes out, "Already queued"
    assert_equal 1, links.count
  end

  def test_add_command_without_url_returns_usage
    require "cli/add_command"

    _, err = capture_io do
      cmd = PodgenCLI::AddCommand.new(["test_pod"], {})
      code = cmd.run
      assert_equal 2, code
    end

    assert_includes err, "Usage:"
  end

  def test_add_command_without_podcast_returns_usage
    require "cli/add_command"

    _, err = capture_io do
      cmd = PodgenCLI::AddCommand.new([], {})
      code = cmd.run
      assert_equal 2, code
    end

    assert_includes err, "Usage:"
  end

  # --- LinksCommand ---

  def test_links_command_lists_empty
    require "cli/links_command"

    out, = capture_io do
      cmd = PodgenCLI::LinksCommand.new(["test_pod"], {})
      code = cmd.run
      assert_equal 0, code
    end

    assert_includes out, "No priority links queued"
  end

  def test_links_command_lists_queued_links
    require "cli/links_command"

    links = PriorityLinks.new(File.join(@podcast_dir, "links.yml"))
    links.add("https://example.com/1")
    links.add("https://example.com/2", note: "interesting")

    out, = capture_io do
      cmd = PodgenCLI::LinksCommand.new(["test_pod"], {})
      cmd.run
    end

    assert_includes out, "https://example.com/1"
    assert_includes out, "https://example.com/2"
    assert_includes out, "interesting"
    assert_includes out, "2 priority link(s) queued"
  end

  def test_links_command_remove
    require "cli/links_command"

    links = PriorityLinks.new(File.join(@podcast_dir, "links.yml"))
    links.add("https://example.com/1")
    links.add("https://example.com/2")

    out, = capture_io do
      cmd = PodgenCLI::LinksCommand.new(["--remove", "https://example.com/1", "test_pod"], {})
      cmd.run
    end

    assert_includes out, "Removed"
    assert_equal 1, links.count
  end

  def test_links_command_remove_nonexistent
    require "cli/links_command"

    out, = capture_io do
      cmd = PodgenCLI::LinksCommand.new(["--remove", "https://example.com/nope", "test_pod"], {})
      cmd.run
    end

    assert_includes out, "Not found"
  end

  def test_links_command_clear
    require "cli/links_command"

    links = PriorityLinks.new(File.join(@podcast_dir, "links.yml"))
    links.add("https://example.com/1")
    links.add("https://example.com/2")

    out, = capture_io do
      cmd = PodgenCLI::LinksCommand.new(["--clear", "test_pod"], {})
      cmd.run
    end

    assert_includes out, "Cleared 2 link(s)"
    assert links.empty?
  end

  def test_links_command_clear_empty
    require "cli/links_command"

    out, = capture_io do
      cmd = PodgenCLI::LinksCommand.new(["--clear", "test_pod"], {})
      cmd.run
    end

    assert_includes out, "No links to clear"
  end
end
