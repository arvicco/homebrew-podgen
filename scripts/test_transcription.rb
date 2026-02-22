#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: Transcription engines — transcribes an audio file via OpenAI, ElevenLabs Scribe, or Groq Whisper
# Usage:
#   podgen test transcription <audio_file_path> [open|elab|groq|all]
#   podgen test transcription <podcast_name>    [open|elab|groq|all]

require "bundler/setup"
require "dotenv/load"
require "net/http"
require "uri"
require "tmpdir"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "transcription", "engine_manager")
require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "sources", "rss_source")

VALID_ENGINES = %w[open elab groq all].freeze

def display_engine_result(code, result)
  puts "=== Engine: #{code} ==="
  puts

  if result[:segments].any?
    puts "Speech boundaries: #{result[:speech_start].round(1)}s → #{result[:speech_end].round(1)}s"
    puts "Segments: #{result[:segments].length}"
    puts

    puts "--- Segments (with quality metadata) ---"
    puts "  #{'Idx'.ljust(4)} #{'Time'.ljust(16)} #{'NSProb'.ljust(8)} #{'Compr'.ljust(8)} #{'LogP'.ljust(8)} Text"
    puts "  #{'-' * 100}"
    result[:segments].each_with_index do |seg, i|
      ns = seg[:no_speech_prob].round(3)
      cr = seg[:compression_ratio].round(2)
      lp = seg[:avg_logprob].round(2)

      flags = []
      flags << "NS" if ns > 0.6
      flags << "CR" if cr > 2.4
      flags << "LP" if lp < -1.0
      marker = flags.any? ? " [#{flags.join(',')}]" : ""

      puts "  [#{i.to_s.ljust(3)}] #{seg[:start].round(1).to_s.rjust(6)}→#{seg[:end].round(1).to_s.ljust(7)} " \
        "#{ns.to_s.ljust(8)} #{cr.to_s.ljust(8)} #{lp.to_s.ljust(8)} #{seg[:text][0, 60]}#{marker}"
    end
  else
    puts "Text-only result (no per-segment data)"
  end
  puts

  puts "--- Transcript preview (first 500 chars) ---"
  puts result[:text][0, 500]
  puts "..."
  puts
  puts "Characters: #{result[:text].length}"
end

def save_transcript(code, result, audio_path)
  base = File.basename(audio_path, File.extname(audio_path))
  out_path = File.join(Dir.pwd, "#{base}_transcript_#{code}.txt")
  sentences = result[:text].gsub(/([.!?])(\s+)/, "\\1\n").strip
  File.write(out_path, sentences + "\n")
  puts "  Saved: #{out_path}"
  out_path
end

arg = ARGV[0]
engine_arg = ARGV[1]

unless arg
  $stderr.puts "Usage: podgen test transcription <audio_file_path> [open|elab|groq|all]"
  $stderr.puts "       podgen test transcription <podcast_name>    [open|elab|groq|all]"
  exit 2
end

if engine_arg && !VALID_ENGINES.include?(engine_arg)
  $stderr.puts "Unknown engine: #{engine_arg}. Valid: #{VALID_ENGINES.join(', ')}"
  exit 2
end

if File.exist?(arg)
  audio_path = arg
  language = "sl"
else
  # Treat as podcast name — fetch latest episode from RSS
  config = PodcastConfig.new(arg)
  config.load_env!
  language = config.transcription_language || "sl"

  rss_feeds = config.sources["rss"]
  unless rss_feeds.is_a?(Array) && rss_feeds.any?
    $stderr.puts "Podcast '#{arg}' has no RSS sources configured"
    exit 2
  end

  source = RSSSource.new(feeds: rss_feeds)
  episodes = source.fetch_episodes
  if episodes.empty?
    $stderr.puts "No episodes with audio enclosures found"
    exit 1
  end

  episode = episodes.first
  puts "=== Downloading: \"#{episode[:title]}\" ==="
  puts "URL: #{episode[:audio_url]}"
  puts

  audio_path = File.join(Dir.pwd, "test_source.mp3")
  download_url = episode[:audio_url]
  3.times do
    uri = URI.parse(download_url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
      http.get(uri.request_uri, { "User-Agent" => "PodcastAgent/1.0" })
    end
    if response.is_a?(Net::HTTPRedirection)
      download_url = response["location"]
      puts "Following redirect → #{download_url}"
      next
    end
    File.binwrite(audio_path, response.body)
    break
  end
  puts "Saved to: #{audio_path}"
end

engine_codes = case engine_arg
               when "all" then %w[open elab groq]
               when nil   then %w[open]
               else            [engine_arg]
               end

puts "=== Transcription Test ==="
puts
puts "Audio file: #{audio_path}"
puts "Size: #{(File.size(audio_path) / (1024.0 * 1024)).round(2)} MB"
puts "Language: #{language}"
puts "Engine(s): #{engine_codes.join(', ')}"
puts

manager = Transcription::EngineManager.new(engine_codes: engine_codes, language: language)
result = manager.transcribe(audio_path)

puts

saved_files = []

if engine_codes.length == 1
  display_engine_result(engine_codes.first, result)
  saved_files << save_transcript(engine_codes.first, result, audio_path)

  # Single-engine cleanup
  if result[:cleaned]
    puts "=== Cleaned Transcript (preview, first 500 chars) ==="
    puts result[:cleaned][0, 500]
    puts "..."
    puts

    base = File.basename(audio_path, File.extname(audio_path))
    cleaned_path = File.join(Dir.pwd, "#{base}_transcript_cleaned.txt")
    sentences = result[:cleaned].gsub(/([.!?])(\s+)/, "\\1\n").strip
    File.write(cleaned_path, sentences + "\n")
    saved_files << cleaned_path
    puts "  Saved: #{cleaned_path}"
    puts
  end
else
  result[:all].each do |code, engine_result|
    display_engine_result(code, engine_result)
    saved_files << save_transcript(code, engine_result, audio_path)
    puts
  end

  result[:errors].each do |code, error|
    puts "=== Engine: #{code} — FAILED ==="
    puts "Error: #{error}"
    puts
  end

  # Reconciliation
  if result[:reconciled]
    puts "=== Reconciled Transcript (preview, first 500 chars) ==="
    puts result[:reconciled][0, 500]
    puts "..."
    puts

    base = File.basename(audio_path, File.extname(audio_path))
    reconciled_path = File.join(Dir.pwd, "#{base}_transcript_reconciled.txt")
    sentences = result[:reconciled].gsub(/([.!?])(\s+)/, "\\1\n").strip
    File.write(reconciled_path, sentences + "\n")
    saved_files << reconciled_path
    puts "  Saved: #{reconciled_path}"
    puts
  end

  puts "=== Comparison Summary ==="
  result[:all].each do |code, engine_result|
    puts "  #{code}: #{engine_result[:text].length} chars, #{engine_result[:segments].length} segments"
  end
  if result[:reconciled]
    puts "  reconciled: #{result[:reconciled].length} chars"
  end
  result[:errors].each do |code, _|
    puts "  #{code}: FAILED"
  end
end

puts
puts "=== Saved #{saved_files.length} transcript(s) ==="
saved_files.each { |f| puts "  #{f}" }
