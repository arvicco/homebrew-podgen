# frozen_string_literal: true

require_relative "../test_helper"
require "open3"
require "audio_assembler"

class TestAssembly < Minitest::Test
  def setup
    skip_unless_command("ffmpeg")
    @tmpdir = Dir.mktmpdir("podgen_assembly_test")
    @assembler = AudioAssembler.new

    # Generate synthetic test audio (sine wave tones)
    @intro  = generate_tone(440, 5, "intro")
    @seg1   = generate_tone(523, 8, "seg1")
    @seg2   = generate_tone(659, 6, "seg2")
    @outro  = generate_tone(440, 4, "outro")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end

  def test_full_assembly_with_intro_outro
    output = File.join(@tmpdir, "full.mp3")
    result = @assembler.assemble([@seg1, @seg2], output, intro_path: @intro, outro_path: @outro)

    assert_equal output, result
    assert File.exist?(output), "Output file should exist"
    assert File.size(output) > 0, "Output should be non-empty"

    duration = probe_duration(output)
    # Intro(5) + seg1(8) + seg2(6) + outro(4) = ~23s (crossfades may vary slightly)
    assert_in_delta 23.0, duration, 2.0, "Duration should be ~23s"
  end

  def test_assembly_without_intro_outro
    output = File.join(@tmpdir, "no_music.mp3")
    result = @assembler.assemble([@seg1, @seg2], output)

    assert_equal output, result
    assert File.exist?(output)

    duration = probe_duration(output)
    # seg1(8) + seg2(6) = ~14s
    assert_in_delta 14.0, duration, 1.0
  end

  def test_assembly_with_nonexistent_intro_outro
    output = File.join(@tmpdir, "missing_music.mp3")
    result = @assembler.assemble(
      [@seg1, @seg2], output,
      intro_path: "/nonexistent/intro.mp3",
      outro_path: "/nonexistent/outro.mp3"
    )

    assert_equal output, result
    assert File.exist?(output)
  end

  def test_concat_file_cleaned_up
    output = File.join(@tmpdir, "cleanup.mp3")
    @assembler.assemble([@seg1], output)

    concat = output.sub(/\.mp3$/, "_concat.mp3")
    refute File.exist?(concat), "Intermediate concat file should be removed"
  end

  def test_output_is_valid_mp3
    output = File.join(@tmpdir, "valid.mp3")
    @assembler.assemble([@seg1], output)

    stdout, _, status = Open3.capture3(
      "ffprobe", "-v", "quiet", "-show_entries", "format=format_name", "-of", "csv=p=0", output
    )
    assert status.success?
    assert_includes stdout.strip, "mp3"
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

  def probe_duration(path)
    stdout, = Open3.capture3(
      "ffprobe", "-v", "quiet",
      "-show_entries", "format=duration",
      "-of", "csv=p=0",
      path
    )
    stdout.strip.to_f
  end
end
