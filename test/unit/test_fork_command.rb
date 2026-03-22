# frozen_string_literal: true

require_relative "../test_helper"
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

    # LingQ tracking
    File.write(File.join(@old_output_dir, "lingq_uploads.yml"), {
      "12345" => { "#{@old_name}-2026-03-01" => 100 }
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

  def test_fork_copies_and_renames_lingq_tracking
    capture_io { PodgenCLI::ForkCommand.new([@old_name, @new_name], {}).run }

    new_tracking = File.join(@tmpdir, "output", @new_name, "lingq_uploads.yml")
    data = YAML.load_file(new_tracking)
    assert_equal 100, data["12345"]["#{@new_name}-2026-03-01"]
    refute data["12345"].key?("#{@old_name}-2026-03-01")
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
