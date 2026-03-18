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

  def test_save_script_debug_bottom_links
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

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true })

    content = File.read(path)
    assert_includes content, "## More info"
    assert_includes content, "[Example Article]"
    refute_includes content, "utm_source"
    assert_includes content, "https://example.com/article"
  end

  def test_save_script_debug_bottom_links_custom_title
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{ name: "Main", text: "Content." }],
      sources: [{ title: "Source", url: "https://example.com" }]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, title: "Read more" })

    content = File.read(path)
    assert_includes content, "## Read more"
    refute_includes content, "## More info"
  end

  def test_save_script_debug_bottom_links_with_max
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{ name: "Main", text: "Content." }],
      sources: [
        { title: "Source 1", url: "https://example.com/1" },
        { title: "Source 2", url: "https://example.com/2" },
        { title: "Source 3", url: "https://example.com/3" }
      ]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, max: 2 })

    content = File.read(path)
    assert_includes content, "Source 1"
    assert_includes content, "Source 2"
    refute_includes content, "Source 3"
  end

  def test_save_script_debug_inline_links
    cmd = build_command
    script = {
      title: "Episode",
      segments: [
        { name: "AI News", text: "GPT-5 launched.", sources: [{ title: "GPT-5", url: "https://example.com/gpt5" }] },
        { name: "Wrap-Up", text: "Thanks for listening." }
      ],
      sources: [{ title: "GPT-5", url: "https://example.com/gpt5" }]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, position: "inline" })

    content = File.read(path)
    # Links appear after their segment, not in a bottom section
    assert_includes content, "[GPT-5]"
    refute_includes content, "## More info"
    # Links should be after the segment text, before the next segment
    ai_pos = content.index("GPT-5 launched.")
    link_pos = content.index("[GPT-5]")
    wrapup_pos = content.index("## Wrap-Up")
    assert link_pos > ai_pos
    assert link_pos < wrapup_pos
  end

  def test_save_script_debug_inline_links_with_max
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{
        name: "News", text: "Content.",
        sources: [
          { title: "S1", url: "https://example.com/1" },
          { title: "S2", url: "https://example.com/2" },
          { title: "S3", url: "https://example.com/3" }
        ]
      }],
      sources: []
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, position: "inline", max: 1 })

    content = File.read(path)
    assert_includes content, "S1"
    refute_includes content, "S2"
  end

  def test_save_script_debug_inline_skips_segments_without_sources
    cmd = build_command
    script = {
      title: "Episode",
      segments: [
        { name: "Opening", text: "Welcome." },
        { name: "News", text: "Content.", sources: [{ title: "S1", url: "https://example.com" }] }
      ],
      sources: []
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, position: "inline" })

    content = File.read(path)
    # Only one link list, after News segment
    assert_equal 1, content.scan(/\[S1\]/).length
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

    cmd.send(:save_script_debug, script, path, logger, links_config: nil)

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
