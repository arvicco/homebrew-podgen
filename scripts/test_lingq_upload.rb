#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-uploads the latest generated episode to LingQ.
# Useful when the pipeline succeeded but the LingQ upload failed.
# Usage: podgen test lingq_upload <podcast>

require "bundler/setup"
require "dotenv/load"
require "yaml"
require "tmpdir"

root = File.expand_path("..", __dir__)
ENV["PODGEN_ROOT"] ||= root

require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "agents", "lingq_agent")
require_relative File.join(root, "lib", "agents", "cover_agent")

podcast_name = ARGV[0]
unless podcast_name
  puts "Usage: podgen test lingq_upload <podcast>"
  puts "Available: #{PodcastConfig.available.join(', ')}"
  exit 2
end

config = PodcastConfig.new(podcast_name)
config.load_env!

unless config.lingq_enabled?
  $stderr.puts "LingQ not enabled for #{podcast_name} (need ## LingQ section + LINGQ_API_KEY)"
  exit 1
end

# Find latest episode MP3
mp3s = Dir.glob(File.join(config.episodes_dir, "#{podcast_name}-*.mp3"))
  .reject { |f| File.basename(f).include?("_concat") }
  .sort_by { |f| File.mtime(f) }

if mp3s.empty?
  $stderr.puts "No episodes found in #{config.episodes_dir}"
  exit 1
end

audio_path = mp3s.last
base_name = File.basename(audio_path, ".mp3")

# Find matching transcript
transcript_path = File.join(config.episodes_dir, "#{base_name}_transcript.md")
unless File.exist?(transcript_path)
  $stderr.puts "Transcript not found: #{transcript_path}"
  exit 1
end

# Parse title and transcript text from the markdown file
transcript_lines = File.readlines(transcript_path)
title = transcript_lines.first&.sub(/^#\s*/, "")&.strip || base_name
description = ""
in_transcript = false
transcript_text = []

transcript_lines.each do |line|
  if line.strip == "## Transcript"
    in_transcript = true
    next
  end
  if in_transcript
    transcript_text << line
  elsif !line.start_with?("#") && !line.strip.empty? && transcript_text.empty?
    description = line.strip
  end
end

transcript = transcript_text.join.strip

puts "=== LingQ Upload ==="
puts "  Podcast:    #{podcast_name}"
puts "  Episode:    #{base_name}"
puts "  Title:      #{title}"
puts "  Audio:      #{(File.size(audio_path) / (1024.0 * 1024)).round(2)} MB"
puts "  Transcript: #{transcript.length} chars"
puts

lc = config.lingq_config
language = config.transcription_language
temp_files = []

begin
  # Generate cover image if configured
  image_path = lc[:image]
  if config.cover_generation_enabled?
    cover_path = File.join(Dir.tmpdir, "podgen_cover_#{Process.pid}.jpg")
    temp_files << cover_path

    options = {}
    options[:font] = lc[:font] if lc[:font]
    options[:font_color] = lc[:font_color] if lc[:font_color]
    options[:font_size] = lc[:font_size] if lc[:font_size]
    options[:text_width] = lc[:text_width] if lc[:text_width]
    options[:gravity] = lc[:text_gravity] if lc[:text_gravity]
    options[:x_offset] = lc[:text_x_offset] if lc[:text_x_offset]
    options[:y_offset] = lc[:text_y_offset] if lc[:text_y_offset]

    agent = CoverAgent.new
    agent.generate(
      title: title,
      base_image: lc[:base_image],
      output_path: cover_path,
      options: options
    )
    image_path = cover_path
  end

  # Upload to LingQ
  agent = LingQAgent.new
  lesson_id = agent.upload(
    title: title,
    text: transcript,
    audio_path: audio_path,
    language: language,
    collection: lc[:collection],
    level: lc[:level],
    tags: lc[:tags],
    image_path: image_path,
    accent: lc[:accent],
    status: lc[:status],
    description: description
  )

  puts
  puts "Done! Lesson ID: #{lesson_id}"

rescue => e
  $stderr.puts "Upload failed: #{e.message}"
  $stderr.puts e.backtrace.first(5).join("\n")
  exit 1
ensure
  temp_files.each { |f| File.delete(f) if File.exist?(f) }
end
