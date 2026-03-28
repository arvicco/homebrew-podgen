# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "cli/publish_command"

class TestPublishCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_publish_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- parse_transcript ---

  def test_parse_transcript_with_transcript_section
    path = write_transcript(<<~MD)
      # My Episode Title

      Some description text

      ## Transcript

      First paragraph of transcript.

      Second paragraph.

      ## Vocabulary

      Vocab entries here.
    MD

    cmd = build_command
    title, description, transcript = cmd.send(:parse_transcript, path)

    assert_equal "My Episode Title", title
    assert_equal "Some description text", description
    assert_includes transcript, "First paragraph of transcript."
    assert_includes transcript, "Second paragraph."
    refute_includes transcript, "Vocabulary"
    refute_includes transcript, "Vocab entries"
  end

  def test_parse_transcript_without_transcript_section
    path = write_transcript(<<~MD)
      # Simple Title

      Just body text here.
    MD

    cmd = build_command
    title, description, transcript = cmd.send(:parse_transcript, path)

    assert_equal "Simple Title", title
    assert_nil description
    assert_includes transcript, "Just body text here."
  end

  def test_parse_transcript_empty_description
    path = write_transcript(<<~MD)
      # Title

      ## Transcript

      Body here.
    MD

    cmd = build_command
    title, description, transcript = cmd.send(:parse_transcript, path)

    assert_equal "Title", title
    assert_nil description
    assert_includes transcript, "Body here."
  end

  def test_parse_transcript_minimal
    path = write_transcript("# Just Title\n")

    cmd = build_command
    title, description, _ = cmd.send(:parse_transcript, path)

    assert_equal "Just Title", title
    assert_nil description
  end

  # --- scan_episodes ---

  def test_scan_episodes_finds_mp3s_with_transcripts
    create_mp3("ep-2026-01-15.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# Title\n\nText")

    cmd = build_command
    episodes = cmd.send(:scan_episodes)

    assert_equal 1, episodes.length
    assert_equal "ep-2026-01-15", episodes.first[:base_name]
  end

  def test_scan_episodes_skips_mp3_without_transcript
    create_mp3("ep-2026-01-15.mp3")

    cmd = build_command
    episodes = cmd.send(:scan_episodes)

    assert_empty episodes
  end

  def test_scan_episodes_sorted_chronologically
    create_mp3("ep-2026-01-15.mp3")
    create_mp3("ep-2026-01-16.mp3")
    File.write(File.join(@episodes_dir, "ep-2026-01-15_transcript.md"), "# A")
    File.write(File.join(@episodes_dir, "ep-2026-01-16_transcript.md"), "# B")

    cmd = build_command
    episodes = cmd.send(:scan_episodes)

    assert_equal 2, episodes.length
    assert_equal "ep-2026-01-15", episodes.first[:base_name]
    assert_equal "ep-2026-01-16", episodes.last[:base_name]
  end

  def test_scan_episodes_empty_directory
    cmd = build_command
    assert_empty cmd.send(:scan_episodes)
  end

  # --- upload_tracker ---

  def test_upload_tracker_missing_file
    cmd = build_command
    tracker = cmd.send(:upload_tracker)
    assert_equal({}, tracker.load)
  end

  def test_upload_tracker_existing_file
    tracking_path = File.join(@tmpdir, "uploads.yml")
    File.write(tracking_path, { "lingq" => { "123" => { "ep-a" => 1 } } }.to_yaml)

    cmd = build_command
    tracker = cmd.send(:upload_tracker)
    assert_equal 1, tracker.entries_for(:lingq, "123")["ep-a"]
  end

  def test_upload_tracker_record_and_persist
    cmd = build_command
    tracker = cmd.send(:upload_tracker)
    tracker.record(:lingq, "456", "ep-b", 2)

    tracking_path = File.join(@tmpdir, "uploads.yml")
    assert File.exist?(tracking_path)
    data = YAML.load_file(tracking_path)
    assert_equal 2, data["lingq"]["456"]["ep-b"]
  end

  def test_upload_tracker_handles_non_hash
    tracking_path = File.join(@tmpdir, "uploads.yml")
    File.write(tracking_path, "just a string")

    cmd = build_command
    tracker = cmd.send(:upload_tracker)
    assert_equal({}, tracker.load)
  end

  # --- cleanup_cover ---

  def test_cleanup_cover_deletes_tmpdir_file
    cover = File.join(Dir.tmpdir, "podgen_test_cover_#{Process.pid}.jpg")
    File.write(cover, "image")

    cmd = build_command
    cmd.send(:cleanup_cover, cover)

    refute File.exist?(cover)
  end

  def test_cleanup_cover_ignores_non_tmpdir_file
    # Use a path outside Dir.tmpdir
    cover = File.join(@episodes_dir, "cover.jpg")
    File.write(cover, "image")

    # Temporarily override Dir.tmpdir to be something else so this path won't match
    cmd = build_command
    # The check is image_path.start_with?(Dir.tmpdir), and @episodes_dir is under
    # Dir.tmpdir since mktmpdir creates there. Use absolute home dir instead.
    home_cover = File.expand_path("~/podgen_test_cleanup_cover.jpg")
    File.write(home_cover, "image")
    cmd.send(:cleanup_cover, home_cover)
    assert File.exist?(home_cover)
  ensure
    File.delete(home_cover) if home_cover && File.exist?(home_cover)
  end

  def test_cleanup_cover_ignores_nil
    cmd = build_command
    cmd.send(:cleanup_cover, nil) # should not raise
  end

  # --- rclone_available? ---

  def test_rclone_available_when_installed
    cmd = build_command
    result = cmd.send(:rclone_available?)
    # Result depends on environment — just verify it returns boolean
    assert_includes [true, false], result
  end

  private

  def create_mp3(name)
    File.write(File.join(@episodes_dir, name), "x" * 1000)
  end

  def write_transcript(content)
    path = File.join(@episodes_dir, "test_transcript.md")
    File.write(path, content)
    path
  end

  StubPublishConfig = Struct.new(:episodes_dir, :name, keyword_init: true)

  def build_command
    cmd = PodgenCLI::PublishCommand.allocate
    config = StubPublishConfig.new(episodes_dir: @episodes_dir, name: "test")
    cmd.instance_variable_set(:@config, config)
    cmd
  end
end
