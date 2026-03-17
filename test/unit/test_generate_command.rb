# frozen_string_literal: true

require_relative "../test_helper"
require "cli/generate_command"

class TestGenerateCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_gen_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- save_script_debug ---

  def test_save_script_debug_basic
    cmd = build_command
    script = {
      title: "Test Episode",
      segments: [
        { name: "Opening", text: "Welcome to the show." },
        { name: "Topic", text: "Today we discuss AI." }
      ],
      sources: []
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger)

    content = File.read(path)
    assert_includes content, "# Test Episode"
    assert_includes content, "## Opening"
    assert_includes content, "Welcome to the show."
    assert_includes content, "## Topic"
  end

  def test_save_script_debug_with_links
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{ name: "Main", text: "Content." }],
      sources: [
        { title: "Example Article", url: "https://example.com/article?utm_source=twitter" }
      ]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links: true)

    content = File.read(path)
    assert_includes content, "## More info"
    assert_includes content, "[Example Article]"
    # URL should be cleaned of tracking params
    refute_includes content, "utm_source"
    assert_includes content, "https://example.com/article"
  end

  def test_save_script_debug_without_links
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{ name: "Main", text: "Content." }],
      sources: [{ title: "Source", url: "https://example.com" }]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links: false)

    content = File.read(path)
    refute_includes content, "## More info"
    refute_includes content, "example.com"
  end

  def test_save_script_debug_creates_directory
    cmd = build_command
    script = { title: "Test", segments: [], sources: [] }
    path = File.join(@episodes_dir, "sub", "dir", "script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger)

    assert File.exist?(path)
  end

  # --- verify_ffmpeg! ---

  def test_verify_ffmpeg_success
    cmd = build_command
    logger = StubGenLogger.new

    # Should not raise if ffmpeg is available
    if system("which ffmpeg > /dev/null 2>&1")
      cmd.send(:verify_ffmpeg!, logger) # no error
    else
      assert_raises(RuntimeError) { cmd.send(:verify_ffmpeg!, logger) }
    end
  end

  private

  class StubGenLogger
    attr_reader :messages

    def initialize = @messages = []
    def log(msg) = @messages << msg
    def error(msg) = @messages << msg
    def phase_start(_) = nil
    def phase_end(_) = nil
  end

  def build_command
    PodgenCLI::GenerateCommand.allocate
  end
end
