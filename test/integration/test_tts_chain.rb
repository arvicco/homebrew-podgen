# frozen_string_literal: true

# Integration test: verifies TTS → AudioAssembler chain.
# Synthesizes real audio via ElevenLabs, then assembles into a final MP3.

require_relative "../test_helper"
require "agents/tts_agent"
require "audio_assembler"

class TestTtsChain < Minitest::Test
  def setup
    skip_unless_env("ELEVENLABS_API_KEY", "ELEVENLABS_VOICE_ID")
    skip_unless_command("ffmpeg")
    @tmpdir = Dir.mktmpdir("podgen_tts_chain_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def test_tts_output_is_valid_mp3
    agent = TTSAgent.new
    segments = [
      { name: "Intro", text: "Hello and welcome." },
      { name: "Outro", text: "Goodbye." }
    ]

    paths = agent.synthesize(segments)

    assert_equal 2, paths.length, "Should return one path per segment"
    paths.each do |path|
      assert File.exist?(path), "Audio file should exist"
      assert File.size(path) > 0, "Audio file should not be empty"

      # Validate it's a real MP3 via ffprobe
      duration = AudioAssembler.probe_duration(path)
      assert_kind_of Float, duration
      assert duration > 0, "MP3 duration should be positive"
    end
  end

  def test_tts_to_assembly_roundtrip
    agent = TTSAgent.new
    segments = [
      { name: "Part One", text: "This is the first part of the podcast." },
      { name: "Part Two", text: "And this is the second part. Thanks for listening." }
    ]

    paths = agent.synthesize(segments)

    # Get individual durations
    individual_durations = paths.map { |p| AudioAssembler.probe_duration(p) }
    total_expected = individual_durations.sum

    # Assemble
    output_path = File.join(@tmpdir, "assembled.mp3")
    assembler = AudioAssembler.new
    assembler.assemble(paths, output_path)

    assert File.exist?(output_path), "Assembled MP3 should exist"
    final_duration = AudioAssembler.probe_duration(output_path)

    # Duration should be approximately the sum of segments
    assert_in_delta total_expected, final_duration, 2.0,
      "Assembled duration should be sum of segments ±2s"
  end

  def test_tts_with_intro_outro
    skip_unless_command("ffmpeg")

    agent = TTSAgent.new
    segments = [{ name: "Content", text: "Today we discuss an interesting topic." }]
    paths = agent.synthesize(segments)

    # Generate synthetic intro/outro
    intro_path = generate_tone(440, 3, "intro")
    outro_path = generate_tone(880, 2, "outro")

    output_path = File.join(@tmpdir, "full_episode.mp3")
    assembler = AudioAssembler.new
    assembler.assemble(paths, output_path, intro_path: intro_path, outro_path: outro_path)

    assert File.exist?(output_path), "Full episode MP3 should exist"
    duration = AudioAssembler.probe_duration(output_path)
    # intro(3) + content + outro(2) should be > 5s
    assert duration > 5.0, "Full episode should be at least 5s"
  end

  def test_tts_segments_match_script_count
    agent = TTSAgent.new
    segments = [
      { name: "Seg A", text: "First segment here." },
      { name: "Seg B", text: "Second segment here." },
      { name: "Seg C", text: "Third and final segment." }
    ]

    paths = agent.synthesize(segments)

    assert_equal segments.length, paths.length,
      "Should return exactly one audio file per segment"
    paths.each do |path|
      assert File.size(path) > 0, "Each audio file should be non-empty"
    end
  end

  private

  def generate_tone(freq, duration, label)
    path = File.join(@tmpdir, "#{label}.mp3")
    _, stderr, status = Open3.capture3(
      "ffmpeg", "-y", "-f", "lavfi",
      "-i", "sine=frequency=#{freq}:duration=#{duration}:sample_rate=44100",
      "-c:a", "libmp3lame", "-b:a", "128k",
      path
    )
    raise "Failed to generate #{label}: #{stderr}" unless status.success?
    path
  end
end
