# frozen_string_literal: true

require_relative "../test_helper"
require "prism"

# P10-2 (Q-86): unit files set placeholder API keys process-wide
# (`ENV["…"] ||= "test-key"`), and a full `rake test` loads unit and api
# tests in one process, so a placeholder could un-gate a keyed test.
# (a) skip_unless_env treats placeholder-looking values as absent;
# (b) this lint fails on any NEW `ENV["…"] ||=` under test/. The allowlist
# is the 2026-10-29 census (37 lines in 26 files), keyed file + variable;
# it is burned down only by packets that touch those files, and a stale
# entry fails too so the list shrinks with the code.
class TestEnvPlaceholderLint < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  ALLOWED = {
    "test/support/source_fixture_parsing.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_add_links_commands.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_characterization_reconcilers.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_characterization_segment_builders.rb" => %w[ELEVENLABS_API_KEY],
    "test/unit/test_characterization_translation_paths.rb" => %w[ANTHROPIC_API_KEY OPENAI_API_KEY],
    "test/unit/test_cli_commands.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_cover_command.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_description_agent.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_effort_wiring.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_engine_manager.rb" => %w[GROQ_API_KEY OPENAI_API_KEY],
    "test/unit/test_fork_command.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_image_ranker.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_init_command.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_lingq_agent.rb" => %w[LINGQ_API_KEY],
    "test/unit/test_research_agent.rb" => %w[EXA_API_KEY],
    "test/unit/test_script_agent.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_source_manager.rb" => %w[EXA_API_KEY],
    "test/unit/test_source_subclasses.rb" => %w[ANTHROPIC_API_KEY EXA_API_KEY OPENAI_API_KEY],
    "test/unit/test_topic_agent.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_transcript_merger.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_transcription_engines.rb" => %w[ELEVENLABS_API_KEY GROQ_API_KEY OPENAI_API_KEY],
    "test/unit/test_translation_agent.rb" => %w[ANTHROPIC_API_KEY OPENAI_API_KEY],
    "test/unit/test_tts_agent.rb" => %w[ELEVENLABS_API_KEY ELEVENLABS_VOICE_ID],
    "test/unit/test_utilities.rb" => %w[ANTHROPIC_API_KEY],
    "test/unit/test_voice_command.rb" => %w[ELEVENLABS_API_KEY ELEVENLABS_VOICE_ID],
    "test/unit/test_voicer.rb" => %w[ELEVENLABS_API_KEY ELEVENLABS_VOICE_ID]
  }.freeze

  # [variable, line] for every `ENV["X"] ||= …` in the source.
  def self.env_or_writes(source)
    found = []
    queue = [Prism.parse(source).value]
    while (node = queue.shift)
      if node.is_a?(Prism::IndexOrWriteNode) && node.receiver.is_a?(Prism::ConstantReadNode) &&
          node.receiver.name == :ENV && node.arguments&.arguments&.first.is_a?(Prism::StringNode)
        found << [node.arguments.arguments.first.unescaped, node.location.start_line]
      end
      queue.concat(node.compact_child_nodes)
    end
    found
  end

  # --- (a) skip_unless_env ---

  def test_skip_unless_env_placeholder_value_skips
    %w[test-key test_key TEST fake-key dummy placeholder-value].each do |value|
      with_env("PODGEN_LINT_PROBE_KEY" => value) do
        assert_raises(Minitest::Skip, value) { skip_unless_env("PODGEN_LINT_PROBE_KEY") }
      end
    end
  end

  def test_skip_unless_env_real_looking_value_runs
    with_env("PODGEN_LINT_PROBE_KEY" => "sk-ant-abc123") do
      skip_unless_env("PODGEN_LINT_PROBE_KEY") # must not raise
    end
  end

  def test_skip_unless_env_absent_or_empty_skips
    with_env("PODGEN_LINT_PROBE_KEY" => "") do
      assert_raises(Minitest::Skip) { skip_unless_env("PODGEN_LINT_PROBE_KEY") }
    end
    with_env("PODGEN_LINT_PROBE_KEY" => nil) do
      assert_raises(Minitest::Skip) { skip_unless_env("PODGEN_LINT_PROBE_KEY") }
    end
  end

  # --- (b) the lint ---

  def test_lint_finds_a_load_time_env_or_write
    source = %(require "x"\nENV["NEW_API_KEY"] ||= "test-key"\nclass T; end\n)
    assert_equal [["NEW_API_KEY", 2]], self.class.env_or_writes(source)
  end

  def test_lint_ignores_plain_assignment_and_strings
    source = %(ENV["A_KEY"] = "x"\nputs 'ENV["B_KEY"] ||= "y"'\n)
    assert_empty self.class.env_or_writes(source)
  end

  def test_no_new_env_or_write_under_test
    found = Hash.new { |h, k| h[k] = [] }
    Dir.glob(File.join(ROOT, "test", "**", "*.rb")).each do |path|
      rel = path.delete_prefix("#{ROOT}/")
      self.class.env_or_writes(File.read(path)).each { |var, line| found[rel] << [var, line] }
    end

    new_sites = found.flat_map do |rel, sites|
      allowed = ALLOWED.fetch(rel, [])
      sites.filter_map { |var, line| "#{rel}:#{line} ENV[#{var.inspect}] ||=" unless allowed.include?(var) }
    end
    assert_empty new_sites, "new process-wide placeholder ENV writes under test/ — set and restore per test instead (Q-86)"

    stale = ALLOWED.flat_map do |rel, vars|
      (vars - found.fetch(rel, []).map(&:first)).map { |var| "#{rel} #{var}" }
    end
    assert_empty stale, "allowlist entries no longer in the code — remove them from ALLOWED"
  end

  private

  def with_env(pairs)
    saved = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
