#!/usr/bin/env ruby
# frozen_string_literal: true

# Diagnostic script: downloads one episode and saves each trim stage
# as a separate file so you can listen to what's being cut.
#
# Usage: ruby scripts/test_trim.rb [episode_url]
#   If no URL given, fetches the next unprocessed episode from RSS.
#
# Output (in output/trim_test/):
#   1_original.mp3        — raw download
#   2_after_skip_intro.mp3 — after fixed skip_intro cut
#   3_after_bandpass.mp3   — after bandpass music detection trim
#
# Listen to each file to identify where the over-trimming happens.

require "dotenv"
Dotenv.load

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "podcast_config"
require "audio_assembler"
require "episode_history"
require_relative "../lib/logger"
require "fileutils"
require "open-uri"
require "rss"

PODCAST = "lahko_noc"
OUTPUT_DIR = File.join(PodcastConfig.root, "output", "trim_test")
FileUtils.mkdir_p(OUTPUT_DIR)

config = PodcastConfig.new(PODCAST)
config.load_env!
logger = PodcastAgent::Logger.new(verbosity: :verbose)
assembler = AudioAssembler.new(logger: logger)

# --- Get episode URL ---
url = ARGV[0]
unless url
  puts "Fetching next episode from RSS..."
  history = EpisodeHistory.new(config.history_path)
  used_urls = history.recent_urls

  feed_urls = config.sources["rss"] || []
  feed_url = feed_urls.first
  abort "No RSS feed configured" unless feed_url

  rss_content = URI.open(feed_url).read
  feed = RSS::Parser.parse(rss_content, false)

  episode = feed.items.find do |item|
    enc = item.enclosure
    enc && !used_urls.include?(enc.url)
  end

  abort "No new episodes found" unless episode
  url = episode.enclosure.url
  puts "Episode: #{episode.title}"
end
puts "URL: #{url}"

# --- Phase 1: Download ---
puts "\n=== Phase 1: Download ==="
original = File.join(OUTPUT_DIR, "1_original.mp3")
unless File.exist?(original)
  data = URI.open(url).read
  File.binwrite(original, data)
end
dur = assembler.probe_duration(original)
puts "  Duration: #{dur.round(1)}s"
puts "  Saved: #{original}"

# --- Phase 2: Skip intro ---
skip = config.skip_intro
if skip && skip > 0
  puts "\n=== Phase 2: Skip fixed intro (#{skip}s) ==="
  after_skip = File.join(OUTPUT_DIR, "2_after_skip_intro.mp3")
  assembler.extract_segment(original, after_skip, skip, dur)
  dur2 = assembler.probe_duration(after_skip)
  puts "  Duration: #{dur.round(1)}s → #{dur2.round(1)}s"
  puts "  Saved: #{after_skip}"
  trim_input = after_skip
else
  puts "\n=== Phase 2: No skip_intro configured, skipping ==="
  trim_input = original
end

# --- Phase 3: Bandpass detection ---
puts "\n=== Phase 3: Bandpass speech boundary detection ==="
bp_start, bp_end = assembler.estimate_speech_boundaries(trim_input)
trim_input_dur = assembler.probe_duration(trim_input)

# Show what the pipeline does: skip intro detection if skip_intro is set
if skip && skip > 0
  puts "  (skip_intro is set → skipping bandpass intro detection, only trimming outro)"
  effective_start = 0
else
  effective_start = [bp_start - 3, 0].max
end
puts "  Raw bandpass: #{bp_start.round(1)}s → #{bp_end.round(1)}s"
puts "  After -3s padding: #{effective_start.round(1)}s → #{bp_end.round(1)}s"
puts "  Cutting: #{effective_start.round(1)}s from start, #{(trim_input_dur - bp_end).round(1)}s from end"

after_bp = File.join(OUTPUT_DIR, "3_after_bandpass.mp3")
assembler.extract_segment(trim_input, after_bp, effective_start, bp_end)
dur3 = assembler.probe_duration(after_bp)
puts "  Duration: #{trim_input_dur.round(1)}s → #{dur3.round(1)}s"
puts "  Saved: #{after_bp}"

# --- Phase 3b: Save the bit that bandpass would cut from the end ---
if bp_end < trim_input_dur
  cut_tail_bp = File.join(OUTPUT_DIR, "3b_cut_tail_bandpass.mp3")
  assembler.extract_segment(trim_input, cut_tail_bp, bp_end, trim_input_dur)
  puts "  Saved cut tail: #{cut_tail_bp} (#{(trim_input_dur - bp_end).round(1)}s)"
end

# --- Phase 4: Refine tail (silence-based outro detection) ---
puts "\n=== Phase 4: Refine tail (silence-based outro detection) ==="
MIN_OUTRO_MUSIC = 15
silences = assembler.detect_silences(after_bp)
puts "  Silence gaps found: #{silences.length} (threshold: -30dB)"

# Show last 10 silence gaps to understand the decision
puts "  Last 10 silence gaps:"
silences.last(10).each do |s|
  remaining = dur3 - s[:end]
  marker = remaining >= MIN_OUTRO_MUSIC ? " ← CANDIDATE (#{remaining.round(1)}s remaining >= #{MIN_OUTRO_MUSIC}s)" : ""
  puts "    #{s[:start].round(1)}s → #{s[:end].round(1)}s  (gap: #{(s[:end] - s[:start]).round(1)}s, remaining: #{remaining.round(1)}s)#{marker}"
end

# Replicate the pipeline logic
speech_end = nil
silences.reverse_each do |s|
  remaining = dur3 - s[:end]
  if remaining >= MIN_OUTRO_MUSIC
    speech_end = s[:start]
    break
  end
end

if speech_end && (dur3 - speech_end) >= 10
  savings = dur3 - speech_end
  puts "  Suspected tail: #{speech_end.round(1)}s → #{dur3.round(1)}s (#{savings.round(1)}s)"

  # Save the suspected tail
  tail_path = File.join(OUTPUT_DIR, "5_suspected_tail.mp3")
  assembler.extract_segment(after_bp, tail_path, speech_end, dur3)
  puts "  Saved: #{tail_path}"

  # Transcribe the tail to check for speech
  puts "\n=== Phase 5: Transcription-verify tail ==="
  require_relative "../lib/transcription/engine_manager"
  lang = config.transcription_language || "sl"
  begin
    if ENV["GROQ_API_KEY"]
      engine = Transcription::GroqEngine.new(language: lang, logger: logger)
    else
      engine = Transcription::OpenaiEngine.new(language: lang, logger: logger)
    end
    result = engine.transcribe(tail_path)
    text = result.is_a?(Hash) ? result[:text] : result.to_s
    words = text.to_s.strip.split(/\s+/).length
    min_words = [savings / 5, 3].max.to_i
    has_speech = words >= min_words
    puts "  Transcription: #{words} words (threshold: #{min_words})"
    puts "  Text: #{text.to_s.strip[0..200]}..." if text.to_s.strip.length > 0
    puts "  Verdict: #{has_speech ? 'SPEECH DETECTED — keep tail' : 'NO SPEECH — safe to trim'}"
  rescue => e
    puts "  Transcription failed: #{e.message} — would keep tail (fail-safe)"
    has_speech = true
  end

  if has_speech
    puts "  Decision: keeping tail (speech detected)"
    final_dur = dur3
    refine_applied = false
  else
    puts "  Decision: trimming tail (no speech)"
    after_refine = File.join(OUTPUT_DIR, "4_after_refine.mp3")
    assembler.extract_segment(after_bp, after_refine, 0, speech_end + 1.5)
    dur4 = assembler.probe_duration(after_refine)
    puts "  Duration: #{dur3.round(1)}s → #{dur4.round(1)}s"
    puts "  Saved: #{after_refine}"
    final_dur = dur4
    refine_applied = true
  end
else
  puts "  Decision: no significant trailing music detected, keeping as-is"
  final_dur = dur3
  refine_applied = false
end

# --- Summary ---
puts "\n=== Summary ==="
puts "  Original:         #{dur.round(1)}s"
puts "  After skip_intro: #{(dur - (skip || 0)).round(1)}s  (cut #{skip || 0}s)" if skip && skip > 0
puts "  After bandpass:   #{dur3.round(1)}s  (cut #{(trim_input_dur - dur3).round(1)}s from end)"
puts "  After refine:     #{final_dur.round(1)}s" if refine_applied
puts "  Total removed:    #{(dur - final_dur).round(1)}s"
puts ""
puts "Listen to files in: #{OUTPUT_DIR}"
puts "  1_original.mp3              — full download"
puts "  2_after_skip_intro.mp3      — after #{skip}s fixed cut" if skip && skip > 0
puts "  3_after_bandpass.mp3        — after bandpass trim"
puts "  3b_cut_tail_bandpass.mp3    — what bandpass cut from end" if bp_end < trim_input_dur
puts "  5_suspected_tail.mp3        — suspected tail (transcription-verified)" if speech_end && (dur3 - speech_end) >= 10
puts "  4_after_refine.mp3          — after tail refinement (final)" if refine_applied
