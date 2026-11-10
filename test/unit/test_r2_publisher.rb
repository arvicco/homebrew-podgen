# frozen_string_literal: true

require_relative "../test_helper"
require "r2_publisher"
require "regen_cache"

class TestR2Publisher < Minitest::Test
  ENV_KEYS = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET].freeze

  def setup
    @tmpdir = Dir.mktmpdir("podgen_r2_pub")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
    @uploads_path = File.join(@tmpdir, "uploads.yml")
    RegenCache.reset!

    @saved_env = ENV_KEYS.each_with_object({}) { |k, h| h[k] = ENV[k] }
    ENV_KEYS.each { |k| ENV[k] = "test_value_for_#{k}" }
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
    RegenCache.reset!
    @saved_env.each { |k, v| ENV[k] = v }
  end

  def test_success_returns_synced_true_and_no_errors
    seed_ep("ep-2026-01-15")
    config = stub_config
    publisher = build_publisher(config: config, runner: ->(*) { true })

    result = nil
    capture_io { result = publisher.run }

    assert result.success?
    assert result.synced
    assert_empty result.errors
  end

  def test_rclone_failure_sets_rclone_failed_error
    seed_ep("ep-2026-01-15")
    config = stub_config
    publisher = build_publisher(config: config, runner: ->(*) { false })

    result = nil
    capture_io { result = publisher.run }

    refute result.success?
    refute result.synced
    assert_equal :rclone_failed, result.errors.first[:type]
  end

  def test_missing_env_returns_missing_env_error
    ENV["R2_BUCKET"] = nil
    config = stub_config
    publisher = build_publisher(config: config, runner: ->(*) { true })

    result = nil
    capture_io { result = publisher.run }

    refute result.success?
    refute result.synced
    assert_equal :missing_env, result.errors.first[:type]
    assert_includes result.errors.first[:message], "R2_BUCKET"
  end

  def test_rclone_missing_returns_rclone_missing_error
    config = stub_config
    publisher = build_publisher(config: config, runner: ->(*) { true }, rclone_available: false)

    result = nil
    capture_io { result = publisher.run }

    refute result.success?
    assert_equal :rclone_missing, result.errors.first[:type]
  end

  def test_dry_run_does_not_tweet
    seed_ep("ep-#{recent_date(1)}")
    config = stub_config(twitter_enabled: true)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { true },
      twitter_agent: stub_twitter_agent(tweets),
      options: { dry_run: true }
    )

    capture_io { publisher.run }

    assert_empty tweets
  end

  def test_tweets_new_episodes_on_success_when_twitter_enabled
    seed_ep("ep-#{recent_date(1)}")
    config = stub_config(twitter_enabled: true)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { true },
      twitter_agent: stub_twitter_agent(tweets)
    )

    capture_io { publisher.run }

    assert_equal 1, tweets.length, "should tweet the one new ep"
  end

  # A corrupt uploads.yml used to read as {}: every recent episode looked
  # untweeted, the tweet went out, then the strict record raised — a
  # duplicate tweet live and untracked, repeated every publish.
  def test_tweets_corrupt_ledger_posts_nothing_and_names_the_file
    ["[not: a: map", "- a\n- b\n"].each do |corrupt|
      File.write(@uploads_path, corrupt)
      seed_ep("ep-#{recent_date(1)}")
      tweets = []
      publisher = build_publisher(
        config: stub_config(twitter_enabled: true),
        runner: ->(*) { true },
        twitter_agent: stub_twitter_agent(tweets)
      )

      result = nil
      _out, err = capture_io { result = publisher.run }

      assert_empty tweets, "no tweet may go out against an unreadable ledger (#{corrupt.inspect})"
      assert_includes err, @uploads_path
      assert_equal 0, result.tweets_posted
      assert_equal corrupt, File.read(@uploads_path), "the corrupt ledger is never rewritten"
    end
  end

  def test_does_not_tweet_when_twitter_disabled
    seed_ep("ep-#{recent_date(1)}")
    config = stub_config(twitter_enabled: false)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { true },
      twitter_agent: stub_twitter_agent(tweets)
    )

    capture_io { publisher.run }

    assert_empty tweets
  end

  def test_does_not_tweet_when_rclone_failed
    seed_ep("ep-#{recent_date(1)}")
    config = stub_config(twitter_enabled: true)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { false },
      twitter_agent: stub_twitter_agent(tweets)
    )

    capture_io { publisher.run }

    assert_empty tweets, "no tweets when sync failed"
  end

  # Regression: --date used to be ignored on the R2 path (same bug as
  # YouTube and LingQ). The rclone sync itself stays wholesale by design,
  # but the Twitter side-effect must respect the filter — otherwise
  # `publish <pod> --date X` would tweet about every untweeted episode.
  def test_episode_id_filters_tweets_to_matching_episode
    target_date = recent_date(2)
    seed_ep("ep-#{recent_date(3)}")
    seed_ep("ep-#{target_date}")
    seed_ep("ep-#{recent_date(1)}")
    config = stub_config(twitter_enabled: true)
    tweets = []
    publisher = build_publisher(
      config: config,
      runner: ->(*) { true },
      twitter_agent: stub_twitter_agent(tweets),
      episode_id: target_date
    )

    capture_io { publisher.run }

    assert_equal 1, tweets.length
    assert_match(/ep-#{target_date}/, tweets.first)
  end

  # Q-159 (2): the sync stays show-wide by design, so an episode id must not
  # read as a scoped upload — the run says what the id scopes.
  def test_run_with_episode_id_says_sync_is_show_wide
    seed_ep("ep-2026-01-15")
    calls = []
    runner = lambda do |env:, args:|
      calls << args
      true
    end
    publisher = build_publisher(config: stub_config, runner: runner, episode_id: "2026-01-15")

    out, = capture_io { publisher.run }

    assert_match(/R2 sync is show-wide .*2026-01-15 scopes the tweets only/, out)
    assert_includes calls.first, "episodes/*.mp3"
  end

  def test_run_without_episode_id_prints_no_scope_line
    seed_ep("ep-2026-01-15")
    out, = capture_io { build_publisher(config: stub_config, runner: ->(*) { true }).run }

    refute_match(/show-wide/, out)
  end

  def test_calls_regen_cache_once_per_pod
    seed_ep("ep-2026-01-15")
    config = stub_config
    regen_calls = 0
    publisher = build_publisher(config: config, runner: ->(*) { true })
    publisher.define_singleton_method(:regenerate!) { regen_calls += 1 }

    capture_io { publisher.run }
    capture_io { build_publisher(config: config, runner: ->(*) { true }).tap { |p| p.define_singleton_method(:regenerate!) { regen_calls += 1 } }.run }

    assert_equal 1, regen_calls, "RegenCache memo must skip regen on second call for same pod"
  end

  # P18-10 pin: the tweet selection (scan_eligible_episodes) and status's
  # tweet-stall dates (StatusCommand#announced_episode_dates) apply one
  # language filter, for every shape of the `## Twitter` languages value.
  def test_announced_language_filter_tweets_and_status_agree_pinned
    require "cli/status_command"
    %w[pod-2026-10-01 pod-2026-10-02-es pod-2026-10-03-it].each do |b|
      File.write(File.join(@episodes_dir, "#{b}.mp3"), "x")
      File.write(File.join(@episodes_dir, "#{b}_transcript.md"), "# T\n")
    end
    config = StubR2Config.new(episodes_dir: @episodes_dir)
    config.define_singleton_method(:language_for_episode) { |b| b[/-(es|it)\z/, 1] || "en" }
    publisher = build_publisher(config: config, runner: ->(*) { true })
    status = PodgenCLI::StatusCommand.new([], {})
    {:all => %w[01 02 03], nil => %w[01], [] => %w[01], %w[es] => %w[02],
     %w[es it] => %w[02 03], "es" => %w[02], "en,es" => %w[01 02]}.each do |langs, days|
      dates = days.map { |d| Date.new(2026, 10, d.to_i) }
      tweeted = publisher.send(:scan_eligible_episodes, Date.new(2026, 1, 1), langs)
      assert_equal dates, tweeted.map { |ep| EpisodeFiltering.parse_date(ep[:base_name]) }, "tweets #{langs.inspect}"
      assert_equal dates, status.send(:announced_episode_dates, config, langs), "status #{langs.inspect}"
    end
  end

  def test_regen_failure_warning_prints_even_when_quiet
    # Pins the PublisherShared consolidation choice: a failed site/feed
    # regen is a skippable failure that must be VISIBLE regardless of
    # verbosity (previously R2/LingQ gated it behind :verbose).
    require "cli/rss_command"
    publisher = build_publisher(config: stub_config, runner: ->(*) { true },
      options: {verbosity: :quiet})

    err = nil
    PodgenCLI::RssCommand.stub(:new, ->(*) { raise "regen exploded" }) do
      _out, err = capture_io { publisher.send(:regenerate!) }
    end

    assert_match(/site\/feed regen failed/, err)
    assert_match(/RuntimeError/, err)
  end

  private

  StubR2Config = Struct.new(:episodes_dir, :name, :base_url, :image,
    :transcription_language, :_twitter, keyword_init: true) do
    def initialize(episodes_dir:, name: "test_pod", base_url: "https://example.com",
                   image: nil, transcription_language: "en", _twitter: nil)
      super
    end
    def twitter_enabled? = !_twitter.nil?
    def twitter_config = _twitter
    def primary_language = transcription_language
    def language_for_episode(_) = transcription_language
    def site_episode_url(b) = "#{base_url}/site/episodes/#{b}.html"
  end

  def stub_config(twitter_enabled: false)
    tw = twitter_enabled ? { since: 30, template: "{title}", languages: :all } : nil
    StubR2Config.new(
      episodes_dir: @episodes_dir,
      name: "test_pod",
      base_url: "https://example.com",
      transcription_language: "en",
      _twitter: tw
    )
  end

  # Tweet eligibility uses a rolling window (Date.today - twitter[:since]),
  # so tweet tests must seed dates relative to today — hardcoded dates age
  # out of the window and turn the assertions into time bombs.
  def recent_date(days_ago)
    (Date.today - days_ago).iso8601
  end

  def seed_ep(base)
    File.write(File.join(@episodes_dir, "#{base}.mp3"), "x" * 100)
    File.write(File.join(@episodes_dir, "#{base}_transcript.md"), "# Title #{base}\n\nDescription text\n\n## Transcript\n\nBody.\n")
  end

  def build_publisher(config:, runner:, twitter_agent: nil, options: {}, rclone_available: true, episode_id: nil)
    R2Publisher.new(
      config: config,
      options: options,
      runner: runner,
      twitter_agent: twitter_agent,
      tracker_path: @uploads_path,
      rclone_available: rclone_available,
      episode_id: episode_id
    )
  end

  def stub_twitter_agent(tweets)
    agent = Object.new
    agent.define_singleton_method(:post_episode) do |title:, **_|
      tweets << title
      "tw_#{tweets.length}"
    end
    agent
  end
end
