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
    result = cmd.send(:filter_by_date, paths, Date.parse("2026-04-26"), nil)
    assert_equal 2, result.length
    refute_includes result, "/x/pod-2026-04-25_script.md"
  end

  def test_filter_by_date_with_suffix_narrows_to_exact_basename
    cmd = build_command
    paths = [
      "/x/pod-2026-04-26_script.md",
      "/x/pod-2026-04-26a_script.md",
      "/x/pod-2026-04-26a-jp_script.md",
      "/x/pod-2026-04-26b_script.md"
    ]
    result = cmd.send(:filter_by_date, paths, Date.parse("2026-04-26"), "a")
    assert_equal 2, result.length
    assert(result.all? { |p| p.include?("04-26a") })
  end

  def test_command_accepts_positional_date
    cmd = PodgenCLI::RenderCommand.new(["mypod", "2026-04-26"], { verbosity: :normal })
    assert_equal Date.new(2026, 4, 26), cmd.episode_date
    assert_equal "mypod", cmd.instance_variable_get(:@podcast_name)
  end

  def test_command_accepts_positional_date_with_suffix
    cmd = PodgenCLI::RenderCommand.new(["mypod", "0426b"], { verbosity: :normal })
    today = Date.today
    assert_equal Date.new(today.year, 4, 26), cmd.episode_date
    assert_equal "b", cmd.episode_suffix
  end

  def test_command_rejects_date_and_last_together
    assert_raises(OptionParser::ParseError) do
      PodgenCLI::RenderCommand.new(["mypod", "--date", "2026-04-26", "--last", "3"], { verbosity: :normal })
    end
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

  # ── configured language rule (P5-2a, Q-52) ───────────────────────
  # The 8-row basename table of test_characterization_filename_scheme.rb.
  # Only rows whose two-letter tail is NOT configured differ from the old
  # any-two-letter rule (no real episode file has one).
  TABLE = %w[
    pod-2026-01-15 pod-2026-01-15a pod-2026-01-15z pod-2026-01-15-es
    pod-2026-01-15b-es pod-2026-01-15-ai pod-2026-01-15-jp pod-2026-01-15-esp
  ].freeze
  TABLE_PATHS = TABLE.map { |b| "/x/#{b}_script.md" }.sort.freeze

  # [--lang en selection, --date 2026-01-15b selection] per configuration.
  EXPECTED = {
    nil => [ # old any-two-letter rule (no languages passed)
      %w[pod-2026-01-15-esp pod-2026-01-15 pod-2026-01-15a pod-2026-01-15z],
      %w[pod-2026-01-15b-es]
    ],
    %w[en] => [
      %w[pod-2026-01-15-ai pod-2026-01-15-es pod-2026-01-15-esp pod-2026-01-15-jp
        pod-2026-01-15 pod-2026-01-15a pod-2026-01-15b-es pod-2026-01-15z],
      []
    ],
    %w[en ja] => [
      %w[pod-2026-01-15-ai pod-2026-01-15-es pod-2026-01-15-esp pod-2026-01-15-jp
        pod-2026-01-15 pod-2026-01-15a pod-2026-01-15b-es pod-2026-01-15z],
      []
    ],
    %w[en es it jp] => [
      %w[pod-2026-01-15-ai pod-2026-01-15-esp pod-2026-01-15 pod-2026-01-15a pod-2026-01-15z],
      %w[pod-2026-01-15b-es]
    ]
  }.freeze

  def test_filters_table_follow_configured_rule
    cmd = build_command
    EXPECTED.each do |codes, (lang_en, date_b)|
      by_lang = cmd.send(:filter_by_lang, TABLE_PATHS, "en", languages: codes)
      by_date = cmd.send(:filter_by_date, TABLE_PATHS, Date.parse("2026-01-15"), "b", languages: codes)
      assert_equal lang_en, by_lang.map { |p| File.basename(p, "_script.md") }, codes.inspect
      assert_equal date_b, by_date.map { |p| File.basename(p, "_script.md") }, codes.inspect
    end
  end

  def test_filter_by_last_n_unconfigured_tail_is_its_own_episode
    cmd = build_command
    paths = %w[/x/pod-2026-04-26_script.md /x/pod-2026-04-26-es_script.md /x/pod-2026-04-26-ai_script.md]
    # "-ai" is its own (latest-sorting) episode, not a variant of 04-26
    result = cmd.send(:filter_by_last_n, paths, 1, languages: %w[en es])
    assert_equal %w[/x/pod-2026-04-26-ai_script.md], result
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
