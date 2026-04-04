# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "stringio"
require "fileutils"
require "cli"
require "cli/tweet_command"

class TestTweetCommand < Minitest::Test
  TWITTER_ENV_KEYS = %w[TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET TWITTER_ACCESS_TOKEN TWITTER_ACCESS_SECRET].freeze

  def setup
    @tmpdir = Dir.mktmpdir("podgen_tweet_test")
    build_test_podcast(@tmpdir)
    ENV["PODGEN_ROOT"] = @tmpdir
    @saved_env = TWITTER_ENV_KEYS.map { |k| [k, ENV[k]] }
    TWITTER_ENV_KEYS.each { |k| ENV[k] = "test-#{k}" }
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
    @saved_env.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end

  # ── Validation ──

  def test_requires_podcast_name
    code, _, err = run_cli("tweet")
    assert_equal 2, code
    assert_includes err, "Usage:"
  end

  def test_requires_episode_id
    code, _, err = run_cli("tweet", "twpod")
    assert_equal 2, code
    assert_includes err, "Usage: podgen tweet"
  end

  def test_rejects_unknown_podcast
    code, _, err = run_cli("tweet", "nonexistent", "2026-03-15")
    assert_equal 2, code
    assert_includes err, "Unknown podcast"
  end

  def test_requires_twitter_section_in_guidelines
    # Remove Twitter section from guidelines
    File.write(File.join(@tmpdir, "podcasts", "twpod", "guidelines.md"), "## Podcast\n- name: Tw Pod\n- type: news\n")
    code, _, err = run_cli("tweet", "twpod", "2026-03-15")
    assert_equal 2, code
    assert_includes err, "Twitter not configured"
  end

  def test_dry_run_works_without_env_vars
    create_episode("twpod-2026-03-15")
    @saved_env.each { |k, _| ENV.delete(k) }
    code, out, = run_cli("tweet", "twpod", "2026-03-15", "--dry-run")
    assert_equal 0, code
    assert_includes out, "Test Episode"
  end

  def test_requires_env_vars_for_real_post
    create_episode("twpod-2026-03-15")
    @saved_env.each { |k, _| ENV.delete(k) }
    code, _, err = run_cli("tweet", "twpod", "2026-03-15")
    assert_equal 2, code
    assert_includes err, "TWITTER_* env vars not set"
  end

  def test_episode_not_found
    code, _, err = run_cli("tweet", "twpod", "2099-01-01")
    assert_equal 1, code
    assert_includes err, "No episode found"
  end

  # ── Dry run ──

  def test_dry_run_shows_tweet_text
    create_episode("twpod-2026-03-15")
    code, out, = run_cli("tweet", "twpod", "2026-03-15", "--dry-run")
    assert_equal 0, code
    assert_includes out, "[dry-run]"
    assert_includes out, "Test Episode"
  end

  def test_dry_run_works_with_script_md
    create_script_episode("twpod-2026-03-12")
    code, out, = run_cli("tweet", "twpod", "2026-03-12", "--dry-run")
    assert_equal 0, code
    assert_includes out, "News Episode"
  end

  def test_dry_run_with_template_override
    create_episode("twpod-2026-03-15")
    code, out, = run_cli("tweet", "twpod", "2026-03-15", "--dry-run", "--template", "Trending! {title}\\n{mp3_url}")
    assert_equal 0, code
    assert_includes out, "Trending! Test Episode"
    refute_includes out, "site_url"
  end

  def test_dry_run_default_template_uses_site_url
    create_episode("twpod-2026-03-15")
    code, out, = run_cli("tweet", "twpod", "2026-03-15", "--dry-run")
    assert_equal 0, code
    # Default template uses {site_url}, not {mp3_url}
    refute_includes out, ".mp3"
  end

  # ── Already tweeted ──

  def test_already_tweeted_without_force
    create_episode("twpod-2026-03-15")
    # Pre-record a tweet
    tracker_path = File.join(@tmpdir, "output", "twpod", "uploads.yml")
    File.write(tracker_path, YAML.dump("twitter" => { "posts" => { "twpod-2026-03-15" => "old-tweet-id" } }))

    code, _, err = run_cli("tweet", "twpod", "2026-03-15")
    assert_equal 1, code
    assert_includes err, "Already tweeted"
  end

  private

  def create_episode(base_name)
    episodes_dir = File.join(@tmpdir, "output", "twpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "#{base_name}.mp3"), "fake-audio")
    File.write(File.join(episodes_dir, "#{base_name}_transcript.md"), <<~MD)
      # Test Episode

      A test episode description.

      ## Transcript

      Hello world.
    MD
  end

  def run_cli(*args)
    old_stdout, old_stderr = $stdout, $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    code = PodgenCLI.run(args.flatten)
    [code, $stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  def create_script_episode(base_name)
    episodes_dir = File.join(@tmpdir, "output", "twpod", "episodes")
    FileUtils.mkdir_p(episodes_dir)
    File.write(File.join(episodes_dir, "#{base_name}.mp3"), "fake-audio")
    File.write(File.join(episodes_dir, "#{base_name}_script.md"), <<~MD)
      # News Episode

      A news episode description.

      ## Script

      Today's top stories.
    MD
  end

  def build_test_podcast(dir)
    pod = File.join(dir, "podcasts", "twpod")
    out = File.join(dir, "output", "twpod", "episodes")
    FileUtils.mkdir_p([pod, out])

    File.write(File.join(pod, "guidelines.md"), <<~MD)
      ## Podcast
      - name: Tw Pod
      - type: news

      ## Twitter
      - template: New: {title} {url}
    MD

    File.write(File.join(pod, "queue.yml"), YAML.dump("topics" => ["testing"]))
  end
end
