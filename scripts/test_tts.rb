#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 4 test: Run the TTSAgent with short text segments
# Uses minimal text to keep ElevenLabs API costs low during testing.

require "bundler/setup"
require "dotenv/load"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "agents", "tts_agent")

puts "=== TTS Agent Test ==="
puts

segments = [
  {
    name: "intro",
    text: "Here's what caught my eye this week. The AI agent framework landscape has shifted significantly in early 2026, and a lot of developers are still catching up."
  },
  {
    name: "outro",
    text: "That's all for today. The takeaway is simple: pick the tool that matches your actual complexity, not the one with the most features. See you next time."
  }
]

agent = TTSAgent.new
audio_paths = agent.synthesize(segments)

puts
puts "=== Results ==="
audio_paths.each_with_index do |path, i|
  size_kb = (File.size(path) / 1024.0).round(1)
  puts "  [#{i + 1}] #{path} (#{size_kb} KB)"
end

puts
puts "=== Test complete: #{audio_paths.length} audio files generated ==="
