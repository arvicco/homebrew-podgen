#!/usr/bin/env ruby
# frozen_string_literal: true

# Test: TranscriptionAgent — transcribes an audio file via OpenAI Whisper
# Usage:
#   podgen test transcription <audio_file_path>
#   podgen test transcription <podcast_name>        # fetches latest episode from RSS

require "bundler/setup"
require "dotenv/load"
require "net/http"
require "uri"
require "tmpdir"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "agents", "transcription_agent")
require_relative File.join(root, "lib", "podcast_config")
require_relative File.join(root, "lib", "sources", "rss_source")

arg = ARGV[0]

unless arg
  $stderr.puts "Usage: podgen test transcription <audio_file_path>"
  $stderr.puts "       podgen test transcription <podcast_name>"
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

puts "=== Transcription Test ==="
puts
puts "Audio file: #{audio_path}"
puts "Size: #{(File.size(audio_path) / (1024.0 * 1024)).round(2)} MB"
puts "Language: #{language}"
puts

agent = TranscriptionAgent.new(language: language)
result = agent.transcribe(audio_path)

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

    # Flag suspicious segments
    flags = []
    flags << "NS" if ns > 0.6
    flags << "CR" if cr > 2.4
    flags << "LP" if lp < -1.0
    marker = flags.any? ? " [#{flags.join(',')}]" : ""

    puts "  [#{i.to_s.ljust(3)}] #{seg[:start].round(1).to_s.rjust(6)}→#{seg[:end].round(1).to_s.ljust(7)} " \
      "#{ns.to_s.ljust(8)} #{cr.to_s.ljust(8)} #{lp.to_s.ljust(8)} #{seg[:text][0, 60]}#{marker}"
  end
else
  model = ENV.fetch("WHISPER_MODEL", "gpt-4o-mini-transcribe")
  puts "Model #{model} returned text only (no per-segment data)"
end
puts

puts "--- Full Transcript ---"
puts result[:text]
puts
puts "=== Test complete: #{result[:text].length} characters ==="
