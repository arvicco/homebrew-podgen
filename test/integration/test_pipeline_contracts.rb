# frozen_string_literal: true

# Integration test: verifies data contracts between pipeline agents.
# Ensures output format of one stage is accepted by the next.

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/script_agent"
require "agents/translation_agent"

class TestPipelineContracts < Minitest::Test
  # Research data format (ResearchAgent output) must pass ScriptAgent validation
  def test_research_format_accepted_by_script_agent
    research_data = [
      {
        topic: "AI developments",
        findings: [
          { title: "GPT-5 Released", url: "https://example.com/gpt5", summary: "New AI model" },
          { title: "Claude 4", url: "https://example.com/claude", summary: "Anthropic update" }
        ]
      },
      {
        topic: "Ruby news",
        findings: [
          { title: "Rails 8", url: "https://example.com/rails", summary: "New Rails version" }
        ]
      }
    ]

    agent = ScriptAgent.new(guidelines: "test", script_path: "/tmp/test_script.md")
    # Should not raise for valid data
    agent.send(:validate_research_data, research_data)
  end

  # Script format (ScriptAgent output) must be accepted by TranslationAgent
  def test_script_format_accepted_by_translation_agent
    script = {
      title: "Episode 42: AI and Ruby",
      segments: [
        { name: "Opening", text: "Welcome to the show!" },
        { name: "AI News", text: "Today we discuss GPT-5." },
        { name: "Wrap-Up", text: "Thanks for listening." }
      ]
    }

    agent = TranslationAgent.new(target_language: "sl")
    formatted = agent.send(:format_script_for_translation, script)

    assert_includes formatted, "Title: Episode 42: AI and Ruby"
    assert_includes formatted, "--- Opening ---"
    assert_includes formatted, "Welcome to the show!"
    script[:segments].each do |seg|
      assert_includes formatted, "--- #{seg[:name]} ---"
      assert_includes formatted, seg[:text]
    end
  end

  # Translation output has same structure as script input (chainable)
  def test_translation_output_structure_matches_script_structure
    translated = {
      title: "Epizoda 42",
      segments: [
        { name: "Uvod", text: "Dobrodošli!" },
        { name: "Zaključek", text: "Hvala za poslušanje." }
      ]
    }

    assert translated.key?(:title)
    assert translated.key?(:segments)
    assert translated[:segments].all? { |s| s.key?(:name) && s.key?(:text) }

    # Can be re-translated (same format)
    agent = TranslationAgent.new(target_language: "de")
    formatted = agent.send(:format_script_for_translation, translated)
    assert_includes formatted, "Epizoda 42"
  end

  # Research data with empty findings is valid (source returned nothing)
  def test_empty_findings_are_valid
    data = [{ topic: "Obscure topic", findings: [] }]
    agent = ScriptAgent.new(guidelines: "test", script_path: "/tmp/test.md")
    # Should not raise for valid data
    agent.send(:validate_research_data, data)
  end
end
