# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/fakes"
require "yaml"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "cli/fork_command"

class TestForkCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_fork_test")
    @old_name = "old_pod"
    @new_name = "new_pod"

    # Create podcast config dir
    @old_podcast_dir = File.join(@tmpdir, "podcasts", @old_name)
    FileUtils.mkdir_p(@old_podcast_dir)
    File.write(File.join(@old_podcast_dir, "guidelines.md"),
      "# Test\n## Podcast\nName: Old Pod Title\nAuthor: Tester\n## Format\nfoo\n## Tone\nbar")
    File.write(File.join(@old_podcast_dir, "queue.yml"), { "topics" => ["AI"] }.to_yaml)
    File.write(File.join(@old_podcast_dir, "cover.jpg"), "fake image")

    # Create output dir with episodes
    @old_output_dir = File.join(@tmpdir, "output", @old_name)
    @old_episodes_dir = File.join(@old_output_dir, "episodes")
    FileUtils.mkdir_p(@old_episodes_dir)

    File.write(File.join(@old_episodes_dir, "#{@old_name}-2026-03-01.mp3"), "audio1")
    File.write(File.join(@old_episodes_dir, "#{@old_name}-2026-03-01_script.md"), "# Title\ntranscript1")
    File.write(File.join(@old_episodes_dir, "#{@old_name}-2026-03-01_script.html"), "<p>transcript1</p>")
    File.write(File.join(@old_episodes_dir, "#{@old_name}-2026-03-02.mp3"), "audio2")
    File.write(File.join(@old_episodes_dir, "#{@old_name}-2026-03-02-es.mp3"), "audio2es")

    # History
    File.write(File.join(@old_output_dir, "history.yml"), [
      { "date" => "2026-03-01", "title" => "First", "topics" => ["AI"], "urls" => ["https://a.com"] },
      { "date" => "2026-03-02", "title" => "Second", "topics" => ["BTC"], "urls" => ["https://b.com"] }
    ].to_yaml)

    # Upload tracking (unified format)
    File.write(File.join(@old_output_dir, "uploads.yml"), {
      "lingq" => { "12345" => { "#{@old_name}-2026-03-01" => 100 } }
    }.to_yaml)

    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # --- argument validation ---

  def test_fork_no_args_returns_usage
    _, err = capture_io do
      code = PodgenCLI::ForkCommand.new([], {}).run
      assert_equal 2, code
    end
    assert_includes err, "Usage:"
  end

  def test_fork_missing_new_name_returns_usage
    _, err = capture_io do
      code = PodgenCLI::ForkCommand.new([@old_name], {}).run
      assert_equal 2, code
    end
    assert_includes err, "Usage:"
  end

  def test_fork_target_already_exists_returns_error
    FileUtils.mkdir_p(File.join(@tmpdir, "podcasts", @new_name))
    _, err = capture_io do
      code = PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run
      assert_equal 1, code
    end
    assert_includes err, "already exists"
  end

  # --- successful fork ---

  def test_fork_copies_config_dir
    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_dir = File.join(@tmpdir, "podcasts", @new_name)
    assert Dir.exist?(new_dir)
    assert File.exist?(File.join(new_dir, "guidelines.md"))
    assert File.exist?(File.join(new_dir, "queue.yml"))
    assert File.exist?(File.join(new_dir, "cover.jpg"))
  end

  def test_fork_renames_episode_files
    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_episodes = File.join(@tmpdir, "output", @new_name, "episodes")
    assert File.exist?(File.join(new_episodes, "#{@new_name}-2026-03-01.mp3"))
    assert File.exist?(File.join(new_episodes, "#{@new_name}-2026-03-01_script.md"))
    assert File.exist?(File.join(new_episodes, "#{@new_name}-2026-03-01_script.html"))
    assert File.exist?(File.join(new_episodes, "#{@new_name}-2026-03-02.mp3"))
    assert File.exist?(File.join(new_episodes, "#{@new_name}-2026-03-02-es.mp3"))
  end

  def test_fork_copies_history
    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_history = File.join(@tmpdir, "output", @new_name, "history.yml")
    entries = YAML.load_file(new_history)
    assert_equal 2, entries.length
    assert_equal "First", entries.first["title"]
  end

  # P19-3 (Q-124): explicit basenames follow the renamed episode files.
  def test_fork_rewrites_explicit_history_basenames_to_new_name
    File.write(File.join(@old_output_dir, "history.yml"), [
      { "date" => "2026-03-01", "title" => "First", "basename" => "#{@old_name}-2026-03-01" },
      { "date" => "2026-03-02", "title" => "Second" }
    ].to_yaml)

    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_history = File.join(@tmpdir, "output", @new_name, "history.yml")
    assert_equal [
      { "date" => "2026-03-01", "title" => "First", "basename" => "#{@new_name}-2026-03-01" },
      { "date" => "2026-03-02", "title" => "Second" }
    ], YAML.load_file(new_history)
    require "history_maps"
    titles = HistoryMaps.build(history_path: new_history, podcast_name: @new_name,
      episodes_dir: File.join(@tmpdir, "output", @new_name, "episodes")).first
    assert_equal "First", titles["#{@new_name}-2026-03-01.mp3"]
    assert_equal "Second", titles["#{@new_name}-2026-03-02.mp3"]
    assert_includes File.read(File.join(@old_output_dir, "history.yml")), "basename: #{@old_name}-2026-03-01"
  end

  # Q-160 point 5: the old name is renamed only as a whole leading token —
  # `old_pod` never rewrites an `old_pod2-…` basename.
  def test_fork_renames_only_the_whole_name_before_a_dash
    File.write(File.join(@old_episodes_dir, "#{@old_name}2-2026-03-03.mp3"), "other")
    File.write(File.join(@old_output_dir, "history.yml"), [
      { "date" => "2026-03-01", "title" => "First", "basename" => "#{@old_name}-2026-03-01" },
      { "date" => "2026-03-03", "title" => "Other", "basename" => "#{@old_name}2-2026-03-03" }
    ].to_yaml)
    File.write(File.join(@old_output_dir, "uploads.yml"), {
      "lingq" => { "12345" => { "#{@old_name}-2026-03-01" => 100, "#{@old_name}2-2026-03-03" => 101 } }
    }.to_yaml)

    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_output = File.join(@tmpdir, "output", @new_name)
    assert File.exist?(File.join(new_output, "episodes", "#{@old_name}2-2026-03-03.mp3"))
    refute File.exist?(File.join(new_output, "episodes", "#{@new_name}2-2026-03-03.mp3"))
    assert_equal ["#{@new_name}-2026-03-01", "#{@old_name}2-2026-03-03"],
      YAML.load_file(File.join(new_output, "history.yml")).map { it["basename"] }
    assert_equal({ "#{@new_name}-2026-03-01" => 100, "#{@old_name}2-2026-03-03" => 101 },
      YAML.load_file(File.join(new_output, "uploads.yml"))["lingq"]["12345"])
  end

  def test_fork_legacy_flat_tracking_renames_only_the_whole_name
    File.delete(File.join(@old_output_dir, "uploads.yml"))
    File.write(File.join(@old_output_dir, "lingq_uploads.yml"), {
      "12345" => { "#{@old_name}-2026-03-01" => 100, "#{@old_name}2-2026-03-03" => 101 }
    }.to_yaml)

    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_tracking = File.join(@tmpdir, "output", @new_name, "uploads.yml")
    assert_equal({ "#{@new_name}-2026-03-01" => 100, "#{@old_name}2-2026-03-03" => 101 },
      YAML.load_file(new_tracking)["lingq"]["12345"])
  end

  def test_fork_history_without_basenames_is_copied_byte_identical
    old_bytes = File.read(File.join(@old_output_dir, "history.yml"))

    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    assert_equal old_bytes, File.read(File.join(@tmpdir, "output", @new_name, "history.yml"))
  end

  # P19-3 (Q-124): legacy flat lingq_uploads.yml lands in the unified shape.
  def test_fork_wraps_legacy_lingq_tracking_under_lingq
    File.delete(File.join(@old_output_dir, "uploads.yml"))
    File.write(File.join(@old_output_dir, "lingq_uploads.yml"), {
      "12345" => { "#{@old_name}-2026-03-01" => 100 }
    }.to_yaml)

    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_tracking = File.join(@tmpdir, "output", @new_name, "uploads.yml")
    assert_equal({ "lingq" => { "12345" => { "#{@new_name}-2026-03-01" => 100 } } }, YAML.load_file(new_tracking))
    require "upload_tracker"
    assert UploadTracker.new(new_tracking).tracked?("lingq", "12345", "#{@new_name}-2026-03-01")
  end

  def test_fork_copies_and_renames_upload_tracking
    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_tracking = File.join(@tmpdir, "output", @new_name, "uploads.yml")
    data = YAML.load_file(new_tracking)
    assert_equal 100, data["lingq"]["12345"]["#{@new_name}-2026-03-01"]
    refute data["lingq"]["12345"].key?("#{@old_name}-2026-03-01")
  end

  def test_fork_writes_upload_tracking_through_atomic_writer
    new_tracking = File.join(@tmpdir, "output", @new_name, "uploads.yml")

    written = record_atomic_writes do
      capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }
    end

    assert_includes written, new_tracking
    assert_equal({ "lingq" => { "12345" => { "#{@new_name}-2026-03-01" => 100 } } }.to_yaml, File.read(new_tracking))
    assert_empty Dir.glob(File.join(@tmpdir, "output", @new_name, "*.tmp.*"))
  end

  # Q-140 (P19-4): a corrupt uploads.yml stops the fork before anything is
  # written — no half-forked podcast whose ledger is silently missing (today:
  # config and episodes copied, tracking skipped, exit 0).
  def test_fork_corrupt_upload_tracking_fails_before_copying_anything
    File.write(File.join(@old_output_dir, "uploads.yml"), "- not a hash\n")

    error = nil
    capture_io do
      error = assert_raises(RuntimeError) { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }
    end

    assert_includes error.message, "uploads.yml"
    refute Dir.exist?(File.join(@tmpdir, "podcasts", @new_name))
    refute Dir.exist?(File.join(@tmpdir, "output", @new_name))
  end

  def test_fork_preserves_old_podcast
    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    assert Dir.exist?(@old_podcast_dir)
    assert File.exist?(File.join(@old_episodes_dir, "#{@old_name}-2026-03-01.mp3"))
  end

  def test_fork_returns_zero_on_success
    out, = capture_io do
      code = PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run
      assert_equal 0, code
    end
    assert_includes out, @new_name
  end
end
