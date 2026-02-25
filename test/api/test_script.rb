# frozen_string_literal: true

require_relative "../test_helper"
require "podcast_config"
require "agents/script_agent"

class TestScript < Minitest::Test
  def setup
    skip_unless_env("ANTHROPIC_API_KEY")

    available = PodcastConfig.available
    skip "No podcasts configured" if available.empty?

    @config = PodcastConfig.new(available.first)
    @config.ensure_directories!

    @research_data = [
      {
        topic: "AI developer tools and agent frameworks",
        findings: [
          {
            title: "OpenAI Agents SDK vs LangGraph: 2026 Comparison",
            url: "https://example.com/ai-agents",
            summary: "OpenAI released its Agents SDK in early 2026, offering a simpler alternative to LangGraph."
          },
          {
            title: "Claude Code and the Rise of Agentic Development",
            url: "https://example.com/claude-code",
            summary: "Anthropic's Claude Code CLI tool has become popular among developers."
          }
        ]
      },
      {
        topic: "Ruby on Rails ecosystem updates",
        findings: [
          {
            title: "Rails 8 Authentication Generator",
            url: "https://example.com/rails-auth",
            summary: "Rails 8 introduces a built-in authentication generator."
          }
        ]
      }
    ]
  end

  def test_generate_returns_script_with_segments
    agent = ScriptAgent.new(
      guidelines: @config.guidelines,
      script_path: @config.script_path
    )
    script = agent.generate(@research_data)

    assert_kind_of Hash, script
    assert script[:title], "Script must have :title"
    assert_kind_of Array, script[:segments]
    refute_empty script[:segments]

    script[:segments].each do |seg|
      assert seg[:name], "Segment must have :name"
      assert seg[:text], "Segment must have :text"
      assert seg[:text].length > 0, "Segment text must be non-empty"
    end
  end
end
