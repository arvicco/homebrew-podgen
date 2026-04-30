# frozen_string_literal: true

require_relative "../test_helper"
require "cli/render_command"
require "script_artifact"

class TestRenderCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_render")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_filter_by_date_matches_date_substring
    cmd = build_command
    paths = [
      "/x/pod-2026-04-26_script.md",
      "/x/pod-2026-04-26-jp_script.md",
      "/x/pod-2026-04-25_script.md"
    ]
    result = cmd.send(:filter_by_date, paths, Date.parse("2026-04-26"))
    assert_equal 2, result.length
    refute_includes result, "/x/pod-2026-04-25_script.md"
  end

  def test_filter_by_lang_en_excludes_language_suffixed
    cmd = build_command
    paths = [
      "/x/pod-2026-04-26_script.md",
      "/x/pod-2026-04-26-jp_script.md",
      "/x/pod-2026-04-26-it_script.md"
    ]
    result = cmd.send(:filter_by_lang, paths, "en")
    assert_equal ["/x/pod-2026-04-26_script.md"], result
  end

  def test_filter_by_lang_specific_language
    cmd = build_command
    paths = [
      "/x/pod-2026-04-26_script.md",
      "/x/pod-2026-04-26-jp_script.md",
      "/x/pod-2026-04-26-it_script.md"
    ]
    result = cmd.send(:filter_by_lang, paths, "jp")
    assert_equal ["/x/pod-2026-04-26-jp_script.md"], result
  end

  def test_filter_by_last_n_picks_most_recent_episodes_with_all_languages
    cmd = build_command
    paths = [
      "/x/pod-2026-04-25_script.md",
      "/x/pod-2026-04-25-jp_script.md",
      "/x/pod-2026-04-26_script.md",
      "/x/pod-2026-04-26-jp_script.md",
      "/x/pod-2026-04-27_script.md"
    ]
    result = cmd.send(:filter_by_last_n, paths, 2)
    # Last 2 episodes = 04-26 (en+jp) and 04-27 (en) = 3 paths
    assert_equal 3, result.length
    refute(result.any? { |p| p.include?("04-25") })
  end

  def test_render_rebuilds_md_from_json_with_inline_links
    json_path = File.join(@episodes_dir, "pod-2026-04-26_script.json")
    script = {
      title: "Episode 1",
      segments: [
        { name: "News", text: "Big story.", sources: [{ title: "S1", url: "https://example.com/1" }] }
      ],
      sources: [{ title: "S1", url: "https://example.com/1" }]
    }
    ScriptArtifact.write(json_path, script)
    md_path = json_path.sub(/\.json\z/, ".md")

    # Test the rendering directly without spinning up full PodcastConfig
    require "script_renderer"
    File.write(md_path, ScriptRenderer.render(script, links_config: { show: true, position: "inline" }))

    md = File.read(md_path)
    assert_includes md, "# Episode 1"
    assert_includes md, "## News"
    assert_includes md, "Big story."
    assert_includes md, "[S1](https://example.com/1)"
  end

  private

  def build_command
    PodgenCLI::RenderCommand.allocate
  end
end
