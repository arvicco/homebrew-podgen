# frozen_string_literal: true

require_relative "../test_helper"
require "audio_assembler"

class TestAudioAssembler < Minitest::Test
  # --- Constants ---

  def test_sample_rate
    assert_equal 44_100, AudioAssembler::SAMPLE_RATE
  end

  def test_bitrate
    assert_equal "192k", AudioAssembler::BITRATE
  end

  def test_target_lufs
    assert_equal(-16, AudioAssembler::TARGET_LUFS)
  end

  def test_true_peak
    assert_in_delta(-1.5, AudioAssembler::TRUE_PEAK)
  end

  def test_lra
    assert_equal 11, AudioAssembler::LRA
  end

  def test_intro_fade_out
    assert_equal 3, AudioAssembler::INTRO_FADE_OUT
  end

  def test_outro_fade_in
    assert_equal 2, AudioAssembler::OUTRO_FADE_IN
  end

  # --- self.probe_duration (class method) ---

  def test_probe_duration_class_method_with_real_file
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      generate_tone(tone, duration: 2)

      duration = AudioAssembler.probe_duration(tone)
      assert_kind_of Float, duration
      assert_in_delta 2.0, duration, 0.2
    end
  end

  def test_probe_duration_class_method_returns_nil_for_missing_file
    result = AudioAssembler.probe_duration("/nonexistent/path/to/audio.mp3")
    assert_nil result
  end

  def test_probe_duration_class_method_returns_nil_for_empty_file
    Dir.mktmpdir("assembler_test") do |dir|
      empty = File.join(dir, "empty.mp3")
      FileUtils.touch(empty)
      result = AudioAssembler.probe_duration(empty)
      assert_nil result
    end
  end

  # --- verify_ffmpeg! ---

  def test_verify_ffmpeg_raises_when_not_found
    fake_status = Minitest::Mock.new
    fake_status.expect(:success?, false)

    Open3.stub(:capture3, ["", "", fake_status]) do
      assert_raises(RuntimeError) do
        AudioAssembler.new
      end
    end
  end

  # --- probe_duration (instance method) ---

  def test_instance_probe_duration_with_real_file
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      generate_tone(tone, duration: 3)

      assembler = AudioAssembler.new
      duration = assembler.probe_duration(tone)
      assert_kind_of Float, duration
      assert_in_delta 3.0, duration, 0.2
    end
  end

  def test_instance_probe_duration_caches_result
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      generate_tone(tone, duration: 1)

      assembler = AudioAssembler.new
      d1 = assembler.probe_duration(tone)
      d2 = assembler.probe_duration(tone)
      assert_equal d1, d2
    end
  end

  def test_instance_probe_duration_raises_for_missing_file
    skip_unless_command("ffmpeg")

    assembler = AudioAssembler.new
    assert_raises(RuntimeError) do
      assembler.probe_duration("/nonexistent/path/audio.mp3")
    end
  end

  # --- loudnorm_analyze (private) ---

  def test_loudnorm_analyze_parses_json
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      generate_tone(tone, duration: 2)

      assembler = AudioAssembler.new
      measurements = assembler.send(:loudnorm_analyze, tone)

      assert_kind_of Hash, measurements
      assert measurements.key?("input_i"), "Expected input_i key in measurements"
      assert measurements.key?("input_tp"), "Expected input_tp key in measurements"
      assert measurements.key?("input_lra"), "Expected input_lra key in measurements"
      assert measurements.key?("input_thresh"), "Expected input_thresh key in measurements"
      assert measurements.key?("target_offset"), "Expected target_offset key in measurements"
    end
  end

  # --- loudnorm_apply (private) ---

  def test_loudnorm_apply_creates_output
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      output = File.join(dir, "normalized.mp3")
      generate_tone(tone, duration: 2)

      assembler = AudioAssembler.new
      measurements = assembler.send(:loudnorm_analyze, tone)
      assembler.send(:loudnorm_apply, tone, output, measurements, metadata: { title: "Test" })

      assert File.exist?(output), "Expected normalized output to exist"
      assert File.size(output) > 0, "Expected normalized output to be non-empty"
    end
  end

  def test_loudnorm_apply_with_metadata
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      output = File.join(dir, "meta.mp3")
      generate_tone(tone, duration: 1)

      assembler = AudioAssembler.new
      measurements = assembler.send(:loudnorm_analyze, tone)
      assembler.send(:loudnorm_apply, tone, output, measurements,
                     metadata: { title: "My Title", artist: "My Artist" })

      assert File.exist?(output)
      # Verify metadata was written via ffprobe
      stdout, _, status = Open3.capture3(
        "ffprobe", "-v", "quiet", "-show_entries", "format_tags=title,artist",
        "-of", "csv=p=0", output
      )
      assert status.success?
      assert_includes stdout, "My Title"
      assert_includes stdout, "My Artist"
    end
  end

  # --- concatenate (private) ---

  def test_concatenate_with_intro_fade_out
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      intro = File.join(dir, "intro.mp3")
      main = File.join(dir, "main.mp3")
      output = File.join(dir, "concat.mp3")
      generate_tone(intro, duration: 4)
      generate_tone(main, duration: 2)

      assembler = AudioAssembler.new
      assembler.send(:concatenate, [intro, main], output, intro: intro, outro: nil)

      assert File.exist?(output), "Expected concatenated output to exist"
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 6.0, duration, 0.5
    end
  end

  def test_concatenate_with_segment_pause
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      seg1 = File.join(dir, "seg1.mp3")
      seg2 = File.join(dir, "seg2.mp3")
      seg3 = File.join(dir, "seg3.mp3")
      output = File.join(dir, "concat.mp3")
      generate_tone(seg1, duration: 2)
      generate_tone(seg2, duration: 2)
      generate_tone(seg3, duration: 2)

      assembler = AudioAssembler.new
      assembler.send(:concatenate, [seg1, seg2, seg3], output,
                     intro: nil, outro: nil, segment_pause: 2.0)

      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      # 3 segments × 2s + 2 pauses × 2s = 10s
      assert_in_delta 10.0, duration, 0.5
    end
  end

  def test_concatenate_no_pause_between_intro_and_first_segment
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      intro = File.join(dir, "intro.mp3")
      seg1 = File.join(dir, "seg1.mp3")
      output = File.join(dir, "concat.mp3")
      generate_tone(intro, duration: 3)
      generate_tone(seg1, duration: 2)

      assembler = AudioAssembler.new
      assembler.send(:concatenate, [intro, seg1], output,
                     intro: intro, outro: nil, segment_pause: 2.0)

      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      # intro 3s + segment 2s, NO pause between them
      assert_in_delta 5.0, duration, 0.5
    end
  end

  def test_concatenate_with_outro_fade_in
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      main = File.join(dir, "main.mp3")
      outro = File.join(dir, "outro.mp3")
      output = File.join(dir, "concat.mp3")
      generate_tone(main, duration: 2)
      generate_tone(outro, duration: 3)

      assembler = AudioAssembler.new
      assembler.send(:concatenate, [main, outro], output, intro: nil, outro: outro)

      assert File.exist?(output), "Expected concatenated output to exist"
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 5.0, duration, 0.5
    end
  end

  # --- snip_segments ---

  def test_snip_segments_builds_correct_filter
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      output = File.join(dir, "snipped.mp3")
      generate_tone(tone, duration: 10)

      segments = [
        MockSegment.new(0.0, 3.0),
        MockSegment.new(7.0, 10.0)
      ]

      assembler = AudioAssembler.new
      result = assembler.snip_segments(tone, output, segments)

      assert_equal output, result
      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      # Keep 0-3 and 7-10 = 6 seconds total
      assert_in_delta 6.0, duration, 0.5
    end
  end

  def test_snip_segments_single_segment
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      output = File.join(dir, "snipped.mp3")
      generate_tone(tone, duration: 5)

      segments = [MockSegment.new(1.0, 4.0)]

      assembler = AudioAssembler.new
      assembler.snip_segments(tone, output, segments)

      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 3.0, duration, 0.5
    end
  end

  # --- trim_to_duration ---

  def test_trim_to_duration_shortens_audio
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      output = File.join(dir, "trimmed.mp3")
      generate_tone(tone, duration: 5)

      assembler = AudioAssembler.new
      result = assembler.trim_to_duration(tone, output, 3)

      assert_equal output, result
      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 3.0, duration, 0.3
    end
  end

  def test_trim_to_duration_applies_fade_out
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      output = File.join(dir, "trimmed.mp3")
      generate_tone(tone, duration: 5)

      assembler = AudioAssembler.new
      # Should not raise - fade is applied even for short durations
      assembler.trim_to_duration(tone, output, 1)

      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 1.0, duration, 0.3
    end
  end

  # --- assemble (full integration) ---

  def test_assemble_single_segment
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      seg = File.join(dir, "segment.mp3")
      output = File.join(dir, "output.mp3")
      generate_tone(seg, duration: 2)

      assembler = AudioAssembler.new
      result = assembler.assemble([seg], output)

      assert_equal output, result
      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 2.0, duration, 0.5
    end
  end

  def test_assemble_multiple_segments
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      seg1 = File.join(dir, "seg1.mp3")
      seg2 = File.join(dir, "seg2.mp3")
      output = File.join(dir, "output.mp3")
      generate_tone(seg1, duration: 2)
      generate_tone(seg2, duration: 2)

      assembler = AudioAssembler.new
      result = assembler.assemble([seg1, seg2], output)

      assert_equal output, result
      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 4.0, duration, 0.5
    end
  end

  def test_assemble_with_intro_and_outro
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      intro = File.join(dir, "intro.mp3")
      seg = File.join(dir, "segment.mp3")
      outro = File.join(dir, "outro.mp3")
      output = File.join(dir, "output.mp3")
      generate_tone(intro, duration: 2)
      generate_tone(seg, duration: 2)
      generate_tone(outro, duration: 2)

      assembler = AudioAssembler.new
      result = assembler.assemble([seg], output, intro_path: intro, outro_path: outro)

      assert_equal output, result
      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 6.0, duration, 1.0
    end
  end

  def test_assemble_skips_nonexistent_intro
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      seg = File.join(dir, "segment.mp3")
      output = File.join(dir, "output.mp3")
      generate_tone(seg, duration: 2)

      assembler = AudioAssembler.new
      result = assembler.assemble([seg], output, intro_path: "/nonexistent/intro.mp3")

      assert_equal output, result
      assert File.exist?(output)
    end
  end

  def test_assemble_empty_inputs_returns_nil
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      output = File.join(dir, "output.mp3")

      assembler = AudioAssembler.new
      result = assembler.assemble([], output)

      assert_nil result
    end
  end

  def test_assemble_with_metadata
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      seg = File.join(dir, "segment.mp3")
      output = File.join(dir, "output.mp3")
      generate_tone(seg, duration: 2)

      assembler = AudioAssembler.new
      assembler.assemble([seg], output, metadata: { title: "Episode 1", artist: "Test" })

      assert File.exist?(output)
      stdout, _, status = Open3.capture3(
        "ffprobe", "-v", "quiet", "-show_entries", "format_tags=title,artist",
        "-of", "csv=p=0", output
      )
      assert status.success?
      assert_includes stdout, "Episode 1"
      assert_includes stdout, "Test"
    end
  end

  def test_assemble_cleans_up_intermediate_file
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      seg = File.join(dir, "segment.mp3")
      output = File.join(dir, "output.mp3")
      generate_tone(seg, duration: 2)

      assembler = AudioAssembler.new
      assembler.assemble([seg], output)

      concat_path = output.sub(/\.mp3$/, "_concat.mp3")
      refute File.exist?(concat_path), "Expected intermediate concat file to be cleaned up"
    end
  end

  def test_assemble_creates_output_directory
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      seg = File.join(dir, "segment.mp3")
      output = File.join(dir, "subdir", "deep", "output.mp3")
      generate_tone(seg, duration: 1)

      assembler = AudioAssembler.new
      assembler.assemble([seg], output)

      assert File.exist?(output)
    end
  end

  # --- extract_segment ---

  def test_extract_segment
    skip_unless_command("ffmpeg")

    Dir.mktmpdir("assembler_test") do |dir|
      tone = File.join(dir, "tone.mp3")
      output = File.join(dir, "extracted.mp3")
      generate_tone(tone, duration: 10)

      assembler = AudioAssembler.new
      result = assembler.extract_segment(tone, output, 2.0, 5.0)

      assert_equal output, result
      assert File.exist?(output)
      duration = AudioAssembler.probe_duration(output)
      assert_in_delta 3.0, duration, 0.5
    end
  end

  private

  def generate_tone(path, duration: 1)
    system("ffmpeg", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=#{duration}",
           "-ac", "1", "-ar", "44100", "-b:a", "128k", path,
           out: File::NULL, err: File::NULL)
  end

  MockSegment = Struct.new(:from, :to)
end
