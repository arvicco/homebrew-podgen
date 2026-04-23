# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "cli/init_command"

class TestInitCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_init_test")

    # Create an existing podcast config
    @source_name = "source_pod"
    @source_dir = File.join(@tmpdir, "podcasts", @source_name)
    FileUtils.mkdir_p(@source_dir)
    File.write(File.join(@source_dir, "guidelines.md"),
      "# Podcast Guidelines\n## Podcast\n- name: Source Pod\n- type: language\n## Format\nfoo\n## Tone\nbar")
    File.write(File.join(@source_dir, "queue.yml"), { "topics" => ["AI"] }.to_yaml)
    File.write(File.join(@source_dir, "cover.jpg"), "fake image")
    File.write(File.join(@source_dir, ".env"), "SECRET=value")

    # Create output dir with episodes (should NOT be copied)
    source_output = File.join(@tmpdir, "output", @source_name, "episodes")
    FileUtils.mkdir_p(source_output)
    File.write(File.join(source_output, "#{@source_name}-2026-03-01.mp3"), "audio")

    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # --- argument validation ---

  def test_init_no_args_returns_usage
    _, err = capture_io do
      code = PodgenCLI::InitCommand.new([], {}).run
      assert_equal 2, code
    end
    assert_includes err, "Usage:"
  end

  def test_init_target_already_exists_returns_error
    FileUtils.mkdir_p(File.join(@tmpdir, "podcasts", "existing"))
    _, err = capture_io do
      code = PodgenCLI::InitCommand.new(["existing"], {}).run
      assert_equal 1, code
    end
    assert_includes err, "already exists"
  end

  # --- init from existing (two-arg mode) ---

  def test_init_from_existing_copies_config_dir
    out, = capture_io { PodgenCLI::InitCommand.new([@source_name, "new_pod"], {}).run }

    new_dir = File.join(@tmpdir, "podcasts", "new_pod")
    assert Dir.exist?(new_dir)
    assert File.exist?(File.join(new_dir, "guidelines.md"))
    assert File.exist?(File.join(new_dir, "queue.yml"))
    assert File.exist?(File.join(new_dir, "cover.jpg"))
    assert File.exist?(File.join(new_dir, ".env"))
  end

  def test_init_from_existing_creates_empty_output_dir
    capture_io { PodgenCLI::InitCommand.new([@source_name, "new_pod"], {}).run }

    episodes_dir = File.join(@tmpdir, "output", "new_pod", "episodes")
    assert Dir.exist?(episodes_dir)
    assert_empty Dir.glob(File.join(episodes_dir, "*"))
  end

  def test_init_from_existing_does_not_copy_episodes
    capture_io { PodgenCLI::InitCommand.new([@source_name, "new_pod"], {}).run }

    refute File.exist?(File.join(@tmpdir, "output", "new_pod", "episodes", "#{@source_name}-2026-03-01.mp3"))
  end

  def test_init_from_existing_does_not_copy_history
    File.write(File.join(@tmpdir, "output", @source_name, "history.yml"), [{ "date" => "2026-03-01" }].to_yaml)

    capture_io { PodgenCLI::InitCommand.new([@source_name, "new_pod"], {}).run }

    refute File.exist?(File.join(@tmpdir, "output", "new_pod", "history.yml"))
  end

  def test_init_from_existing_returns_zero
    out, = capture_io do
      code = PodgenCLI::InitCommand.new([@source_name, "new_pod"], {}).run
      assert_equal 0, code
    end
    assert_includes out, "new_pod"
  end

  def test_init_from_nonexistent_source_returns_error
    _, err = capture_io do
      code = PodgenCLI::InitCommand.new(["nonexistent", "new_pod"], {}).run
      assert_equal 2, code
    end
    assert_includes err, "nonexistent"
  end

  # --- init skeleton (single-arg mode) ---

  def test_init_skeleton_creates_podcast_dir
    capture_io { PodgenCLI::InitCommand.new(["brand_new"], {}).run }

    new_dir = File.join(@tmpdir, "podcasts", "brand_new")
    assert Dir.exist?(new_dir)
  end

  def test_init_skeleton_creates_guidelines_with_all_sections
    capture_io { PodgenCLI::InitCommand.new(["brand_new"], {}).run }

    guidelines = File.read(File.join(@tmpdir, "podcasts", "brand_new", "guidelines.md"))

    assert_includes guidelines, "## Podcast"
    assert_includes guidelines, "- name: brand_new"
    assert_includes guidelines, "## Format"
    assert_includes guidelines, "## Tone"
    assert_includes guidelines, "## Sources"
    assert_includes guidelines, "## Audio"
  end

  def test_init_skeleton_creates_queue_yml
    capture_io { PodgenCLI::InitCommand.new(["brand_new"], {}).run }

    queue = File.join(@tmpdir, "podcasts", "brand_new", "queue.yml")
    assert File.exist?(queue)
    data = YAML.load_file(queue)
    assert data.key?("topics")
  end

  def test_init_skeleton_creates_empty_output_dir
    capture_io { PodgenCLI::InitCommand.new(["brand_new"], {}).run }

    episodes_dir = File.join(@tmpdir, "output", "brand_new", "episodes")
    assert Dir.exist?(episodes_dir)
    assert_empty Dir.glob(File.join(episodes_dir, "*"))
  end

  def test_init_skeleton_guidelines_has_comments
    capture_io { PodgenCLI::InitCommand.new(["brand_new"], {}).run }

    guidelines = File.read(File.join(@tmpdir, "podcasts", "brand_new", "guidelines.md"))
    # Template should contain HTML comments explaining sections
    assert_includes guidelines, "<!--"
  end

  def test_init_skeleton_returns_zero
    _, = capture_io do
      code = PodgenCLI::InitCommand.new(["brand_new"], {}).run
      assert_equal 0, code
    end
  end
end
