# frozen_string_literal: true

require_relative "../test_helper"
require "agents/translation_agent"

class TestTranslation < Minitest::Test
  def setup
    skip_unless_env("ANTHROPIC_API_KEY")

    @mock_script = {
      title: "AI Tools and Ruby Updates",
      segments: [
        {
          name: "intro",
          text: "Good morning. Today we're looking at two stories that caught our attention this week."
        },
        {
          name: "segment_1",
          text: "OpenAI released its Agents SDK last month, and it's already shaking up how developers think."
        },
        {
          name: "outro",
          text: "That's it for today. See you next time."
        }
      ]
    }
  end

  def test_translate_returns_translated_script
    translator = TranslationAgent.new(target_language: "es")
    result = translator.translate(@mock_script)

    assert_kind_of Hash, result
    assert result[:title], "Translated script must have :title"
    assert_kind_of Array, result[:segments]
    assert_equal @mock_script[:segments].length, result[:segments].length

    result[:segments].each do |seg|
      assert seg[:name], "Segment must have :name"
      assert seg[:text], "Segment must have :text"
      assert seg[:text].length > 0
    end
  end
end
