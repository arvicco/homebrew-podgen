#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: Run the TranslationAgent with a mock 3-segment English script
# Translates to Spanish by default, or specify a language code as argument.

require "bundler/setup"
require "dotenv/load"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "agents", "translation_agent")

target_language = ARGV[0] || "es"

puts "=== Translation Agent Test ==="
puts "Target language: #{target_language}"
puts

# Mock English script (mimics ScriptAgent output)
mock_script = {
  title: "AI Tools and Ruby Updates — February 19, 2026",
  segments: [
    {
      name: "intro",
      text: "Good morning. Today we're looking at two stories that caught our attention this week. First, the explosion of AI agent frameworks and what it means for developers. And second, a quiet but significant update to the Ruby ecosystem that deserves more attention. Let's get into it."
    },
    {
      name: "segment_1",
      text: "OpenAI released its Agents SDK last month, and it's already shaking up how developers think about building AI-powered applications. The SDK takes a different approach from LangGraph — it's simpler, more opinionated, and focused on two core concepts: tool use and agent handoffs. If you've been building with LangGraph and found the state management overwhelming, this might be worth a look."
    },
    {
      name: "outro",
      text: "That's it for today. Here's your takeaway: if you're building anything with AI agents right now, try both frameworks on a small project before committing. The landscape is moving fast, and the best tool depends entirely on your specific use case. See you next time."
    }
  ]
}

translator = TranslationAgent.new(target_language: target_language)
result = translator.translate(mock_script)

puts
puts "=== Translated Script ==="
puts "Title: #{result[:title]}"
puts "Segments: #{result[:segments].length}"
puts

result[:segments].each do |seg|
  puts "--- #{seg[:name]} (#{seg[:text].length} chars) ---"
  puts seg[:text][0..300]
  puts "..." if seg[:text].length > 300
  puts
end

puts "=== Test complete ==="
