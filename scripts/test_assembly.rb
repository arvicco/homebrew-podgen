#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 5 test: Run the AudioAssembler with synthetic test audio
# Generates short test segments via ffmpeg to avoid TTS API costs.

require "bundler/setup"
require "dotenv/load"
require "open3"
require "tmpdir"
require "fileutils"

root = File.expand_path("..", __dir__)
require_relative File.join(root, "lib", "audio_assembler")

puts "=== Audio Assembly Test ==="
puts

tmp = Dir.mktmpdir("podgen_test")

# Generate synthetic test audio files (sine wave tones at different frequencies)
def generate_tone(path, freq, duration, label)
  # Generate a tone with a spoken-style sample rate
  Open3.capture3(
    "ffmpeg", "-y", "-f", "lavfi",
    "-i", "sine=frequency=#{freq}:duration=#{duration}:sample_rate=44100",
    "-c:a", "libmp3lame", "-b:a", "128k",
    path
  )
  puts "  Generated #{label}: #{path} (#{duration}s, #{freq}Hz)"
end

puts "Generating test audio..."
intro_path = File.join(tmp, "intro.mp3")
seg1_path = File.join(tmp, "segment_1.mp3")
seg2_path = File.join(tmp, "segment_2.mp3")
outro_path = File.join(tmp, "outro.mp3")

generate_tone(intro_path, 440, 5, "intro")      # A4 note, 5 seconds
generate_tone(seg1_path, 523, 8, "segment_1")    # C5 note, 8 seconds
generate_tone(seg2_path, 659, 6, "segment_2")    # E5 note, 6 seconds
generate_tone(outro_path, 440, 4, "outro")        # A4 note, 4 seconds

output_path = File.join(tmp, "final_episode.mp3")

puts
puts "--- Test 1: Full assembly with intro + outro ---"
assembler = AudioAssembler.new
result = assembler.assemble(
  [seg1_path, seg2_path],
  output_path,
  intro_path: intro_path,
  outro_path: outro_path
)
puts "  Result: #{result}"
puts

# Test without intro/outro
output_path_2 = File.join(tmp, "no_music.mp3")
puts "--- Test 2: Assembly without intro/outro ---"
result2 = assembler.assemble(
  [seg1_path, seg2_path],
  output_path_2
)
puts "  Result: #{result2}"
puts

# Test with missing intro/outro paths
output_path_3 = File.join(tmp, "missing_music.mp3")
puts "--- Test 3: Assembly with non-existent intro/outro ---"
result3 = assembler.assemble(
  [seg1_path, seg2_path],
  output_path_3,
  intro_path: "/nonexistent/intro.mp3",
  outro_path: "/nonexistent/outro.mp3"
)
puts "  Result: #{result3}"
puts

# Verify output files
puts "=== Verification ==="
[output_path, output_path_2, output_path_3].each do |path|
  if File.exist?(path)
    size_kb = (File.size(path) / 1024.0).round(1)
    stdout, = Open3.capture3("ffprobe", "-v", "quiet", "-show_entries", "format=duration", "-of", "csv=p=0", path)
    dur = stdout.strip.to_f.round(1)
    puts "  #{File.basename(path)}: #{dur}s, #{size_kb} KB"
  else
    puts "  #{File.basename(path)}: MISSING"
  end
end

# Cleanup
FileUtils.rm_rf(tmp)

puts
puts "=== Test complete ==="
