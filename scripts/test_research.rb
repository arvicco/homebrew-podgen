#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 2 test: Run the ResearchAgent with a small topic set
# Uses 2 results per topic to keep API costs low during testing.

require "bundler/setup"
require "dotenv/load"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "agents", "research_agent")

puts "=== Research Agent Test ==="
puts

agent = ResearchAgent.new(results_per_topic: 2)

topics = ["AI developer tools and agent frameworks", "Ruby on Rails ecosystem updates"]
results = agent.research(topics)

results.each do |entry|
  puts "== #{entry[:topic]} =="
  if entry[:findings].empty?
    puts "  (no results)"
  else
    entry[:findings].each_with_index do |f, i|
      puts "  [#{i + 1}] #{f[:title]}"
      puts "      #{f[:url]}"
      puts "      #{f[:summary]&.slice(0, 200)}..."
      puts
    end
  end
  puts
end

puts "=== Test complete: #{results.sum { |r| r[:findings].length }} total findings ==="
