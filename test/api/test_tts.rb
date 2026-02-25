# frozen_string_literal: true

require_relative "../test_helper"
require "agents/tts_agent"

class TestTTS < Minitest::Test
  def setup
    skip_unless_env("ELEVENLABS_API_KEY", "ELEVENLABS_VOICE_ID")
    @agent = TTSAgent.new
    @segments = [
      {
        name: "intro",
        text: "Here's what caught my eye this week. The AI agent framework landscape has shifted significantly."
      },
      {
        name: "outro",
        text: "That's all for today. Pick the tool that matches your complexity. See you next time."
      }
    ]
  end

  def test_synthesize_returns_audio_files
    paths = @agent.synthesize(@segments)

    assert_kind_of Array, paths
    assert_equal @segments.length, paths.length

    paths.each do |path|
      assert File.exist?(path), "Audio file should exist: #{path}"
      assert File.size(path) > 0, "Audio file should be non-empty: #{path}"
    end
  end
end
