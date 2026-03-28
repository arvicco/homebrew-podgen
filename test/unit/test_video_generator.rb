# frozen_string_literal: true

require_relative "../test_helper"
require "video_generator"

class TestVideoGenerator < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_video_test")
    @generator = VideoGenerator.new
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- ffmpeg_command ---

  def test_ffmpeg_command_includes_all_inputs
    cmd = @generator.send(:ffmpeg_command, "/tmp/cover.jpg", "/tmp/audio.mp3", "/tmp/output.mp4")

    assert_includes cmd, "-loop"
    assert_includes cmd, "/tmp/cover.jpg"
    assert_includes cmd, "/tmp/audio.mp3"
    assert_includes cmd, "/tmp/output.mp4"
  end

  def test_ffmpeg_command_uses_h264_aac
    cmd = @generator.send(:ffmpeg_command, "img.jpg", "audio.mp3", "out.mp4")

    assert_includes cmd, "libx264"
    assert_includes cmd, "aac"
  end

  def test_ffmpeg_command_includes_youtube_optimizations
    cmd = @generator.send(:ffmpeg_command, "img.jpg", "audio.mp3", "out.mp4")

    assert_includes cmd, "stillimage"
    assert_includes cmd, "+faststart"
    assert_includes cmd, "yuv420p"
  end

  def test_ffmpeg_command_scales_to_1920x1080
    cmd = @generator.send(:ffmpeg_command, "img.jpg", "audio.mp3", "out.mp4")

    assert cmd.any? { |arg| arg.include?("1920") && arg.include?("1080") },
      "Command should scale to 1920x1080"
  end

  # --- generate (integration, requires ffmpeg) ---

  def test_generate_creates_mp4_file
    skip "ffmpeg not available" unless ffmpeg_available?

    audio_path = create_test_audio
    image_path = create_test_image
    output_path = File.join(@tmpdir, "episode.mp4")

    @generator.generate(audio_path, image_path, output_path)

    assert File.exist?(output_path), "MP4 file should be created"
    assert File.size(output_path) > 0, "MP4 file should not be empty"
  end

  private

  def ffmpeg_available?
    system("ffmpeg", "-version", out: File::NULL, err: File::NULL)
  end

  def create_test_audio
    path = File.join(@tmpdir, "test.mp3")
    system("ffmpeg", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
      "-c:a", "libmp3lame", "-b:a", "128k", path,
      out: File::NULL, err: File::NULL)
    path
  end

  def create_test_image
    path = File.join(@tmpdir, "test.jpg")
    system("ffmpeg", "-f", "lavfi", "-i", "color=c=blue:s=640x480:d=1",
      "-frames:v", "1", path,
      out: File::NULL, err: File::NULL)
    path
  end
end
