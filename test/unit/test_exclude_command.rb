# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "stringio"
require "cli/exclude_command"
require "sources/rss_source"

class TestExcludeCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_exclude_test")
    @podcast_dir = File.join(@tmpdir, "podcasts", "testpod")
    @output_dir = File.join(@tmpdir, "output", "testpod")
    @history_path = File.join(@output_dir, "history.yml")
    @excluded_path = File.join(@output_dir, "excluded_urls.yml")
    FileUtils.mkdir_p(@podcast_dir)
    FileUtils.mkdir_p(@output_dir)
    File.write(File.join(@podcast_dir, "guidelines.md"), "# Test\n## Format\nfoo\n## Tone\nbar")
    ENV["PODGEN_ROOT"] = @tmpdir
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  def test_exclude_writes_to_excluded_urls_file
    out, = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a", "https://example.com/b"], {})
      code = cmd.run
      assert_equal 0, code
    end

    assert File.exist?(@excluded_path)
    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://example.com/a", "https://example.com/b"], urls
    assert_includes out, "2 URL(s)"
  end

  def test_exclude_does_not_write_to_history
    capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a"], {}).run
    end

    refute File.exist?(@history_path)
  end

  def test_exclude_appends_to_existing_excluded_file
    File.write(@excluded_path, ["https://old.com"].to_yaml)

    capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/new"], {}).run
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://old.com", "https://example.com/new"], urls
  end

  def test_exclude_no_urls_returns_usage_error
    _, err = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new(["testpod"], {})
      code = cmd.run
      assert_equal 2, code
    end

    assert_includes err, "Usage:"
  end

  def test_exclude_no_podcast_returns_usage_error
    _, err = capture_io do
      cmd = PodgenCLI::ExcludeCommand.new([], {})
      code = cmd.run
      assert_equal 2, code
    end

    assert_includes err, "Usage:"
  end

  def test_exclude_strips_tracking_params
    capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a?utm_source=twitter&fbclid=abc"], {}).run
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://example.com/a"], urls
  end

  def test_exclude_skips_urls_already_in_excluded_file
    File.write(@excluded_path, ["https://example.com/a"].to_yaml)

    out, = capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a", "https://example.com/b"], {}).run
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://example.com/a", "https://example.com/b"], urls
    assert_includes out, "1 URL(s)"
    assert_includes out, "1 already excluded"
  end

  def test_exclude_skips_urls_already_in_history
    File.write(@history_path, [{ "date" => "2026-01-01", "title" => "Ep", "topics" => [], "urls" => ["https://example.com/a"] }].to_yaml)

    out, = capture_io do
      PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a", "https://example.com/b"], {}).run
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://example.com/b"], urls
    assert_includes out, "1 already excluded"
  end

  def test_exclude_all_duplicates_reports_nothing_to_add
    File.write(@excluded_path, ["https://example.com/a"].to_yaml)

    out, = capture_io do
      code = PodgenCLI::ExcludeCommand.new(["testpod", "https://example.com/a"], {}).run
      assert_equal 0, code
    end

    assert_includes out, "already excluded"
  end

  # --rss --ask tests

  def test_ask_requires_language_type
    write_guidelines("news", rss: "https://feed.example.com/rss")

    _, err = capture_io do
      code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com", "--ask"], {}).run
      assert_equal 2, code
    end

    assert_includes err, "language"
  end

  def test_ask_displays_episodes_and_excludes_selected
    write_guidelines("language", rss: "https://feed.example.com/rss")

    # Stub RSSSource to return test episodes
    episodes = [
      { title: "Episode One", audio_url: "https://feed.example.com/ep1.mp3", pub_date: Time.new(2026, 3, 29), description: "", link: "" },
      { title: "Episode Two", audio_url: "https://feed.example.com/ep2.mp3", pub_date: Time.new(2026, 3, 28), description: "", link: "" },
      { title: "Episode Three", audio_url: "https://feed.example.com/ep3.mp3", pub_date: Time.new(2026, 3, 27), description: "", link: "" }
    ]

    RSSSource.stub(:new, stub_rss_source(episodes)) do
      out, = capture_io_with_input("1,3") do
        code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com", "--ask"], {}).run
        assert_equal 0, code
      end

      assert_includes out, "Episode One"
      assert_includes out, "Episode Two"
      assert_includes out, "Episode Three"
      assert_includes out, "Excluded 2"
    end

    urls = YAML.load_file(@excluded_path)
    assert_includes urls, "https://feed.example.com/ep1.mp3"
    assert_includes urls, "https://feed.example.com/ep3.mp3"
    refute_includes urls, "https://feed.example.com/ep2.mp3"
  end

  def test_ask_with_count_limits_displayed_episodes
    write_guidelines("language", rss: "https://feed.example.com/rss")

    episodes = (1..10).map do |i|
      { title: "Episode #{i}", audio_url: "https://feed.example.com/ep#{i}.mp3", pub_date: Time.new(2026, 3, 30) - i * 86400, description: "", link: "" }
    end

    RSSSource.stub(:new, stub_rss_source(episodes)) do
      out, = capture_io_with_input("") do
        code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com", "--ask", "3"], {}).run
        assert_equal 0, code
      end

      assert_includes out, "Episode 1"
      assert_includes out, "Episode 3"
      refute_includes out, "Episode 4"
    end
  end

  def test_ask_enter_cancels_without_excluding
    write_guidelines("language", rss: "https://feed.example.com/rss")

    episodes = [
      { title: "Episode One", audio_url: "https://feed.example.com/ep1.mp3", pub_date: Time.new(2026, 3, 29), description: "", link: "" }
    ]

    RSSSource.stub(:new, stub_rss_source(episodes)) do
      out, = capture_io_with_input("") do
        code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com", "--ask"], {}).run
        assert_equal 0, code
      end

      assert_includes out, "Episode One"
    end

    refute File.exist?(@excluded_path)
  end

  def test_ask_skips_already_excluded_urls
    write_guidelines("language", rss: "https://feed.example.com/rss")
    File.write(@excluded_path, ["https://feed.example.com/ep1.mp3"].to_yaml)

    episodes = [
      { title: "Episode One", audio_url: "https://feed.example.com/ep1.mp3", pub_date: Time.new(2026, 3, 29), description: "", link: "" },
      { title: "Episode Two", audio_url: "https://feed.example.com/ep2.mp3", pub_date: Time.new(2026, 3, 28), description: "", link: "" }
    ]

    RSSSource.stub(:new, stub_rss_source(episodes)) do
      out, = capture_io_with_input("") do
        PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com", "--ask"], {}).run
      end

      # Already-excluded ep1 should not appear in the list
      refute_includes out, "Episode One"
      assert_includes out, "Episode Two"
    end
  end

  def test_ask_filters_to_matching_feed
    write_guidelines("language", rss: ["https://feed-a.example.com/rss", "https://feed-b.example.com/rss"])

    episodes = [
      { title: "From Feed B", audio_url: "https://feed-b.example.com/ep1.mp3", pub_date: Time.new(2026, 3, 29), description: "", link: "" }
    ]

    # Capture which feeds were passed to RSSSource.new
    received_feeds = nil
    fake_new = proc do |feeds:, **_|
      received_feeds = feeds
      stub_rss_source(episodes)
    end

    RSSSource.stub(:new, fake_new) do
      capture_io_with_input("") do
        PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed-b", "--ask"], {}).run
      end
    end

    assert_equal 1, received_feeds.length
    assert_includes received_feeds.first, "feed-b"
  end

  def test_ask_no_matching_feed_raises
    write_guidelines("language", rss: "https://feed.example.com/rss")

    _, err = capture_io do
      code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "nonexistent", "--ask"], {}).run
      assert_equal 1, code
    end

    assert_includes err, "No configured RSS feed matches"
  end

  def test_ask_invalid_input_excludes_nothing
    write_guidelines("language", rss: "https://feed.example.com/rss")

    episodes = [
      { title: "Episode One", audio_url: "https://feed.example.com/ep1.mp3", pub_date: Time.new(2026, 3, 29), description: "", link: "" }
    ]

    RSSSource.stub(:new, stub_rss_source(episodes)) do
      out, = capture_io_with_input("abc") do
        code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com", "--ask"], {}).run
        assert_equal 0, code
      end

      assert_includes out, "No valid selections"
    end

    refute File.exist?(@excluded_path)
  end

  def test_ask_out_of_range_numbers_ignored
    write_guidelines("language", rss: "https://feed.example.com/rss")

    episodes = [
      { title: "Episode One", audio_url: "https://feed.example.com/ep1.mp3", pub_date: Time.new(2026, 3, 29), description: "", link: "" }
    ]

    RSSSource.stub(:new, stub_rss_source(episodes)) do
      out, = capture_io_with_input("0,1,99") do
        code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com", "--ask"], {}).run
        assert_equal 0, code
      end

      # Only valid #1 should be excluded; 0 and 99 ignored
      assert_includes out, "Excluded 1"
    end

    urls = YAML.load_file(@excluded_path)
    assert_equal ["https://feed.example.com/ep1.mp3"], urls
  end

  def test_ask_without_rss_uses_all_feeds
    write_guidelines("language", rss: ["https://feed-a.example.com/rss", "https://feed-b.example.com/rss"])

    episodes = [
      { title: "From A", audio_url: "https://feed-a.example.com/ep1.mp3", pub_date: Time.new(2026, 3, 29), description: "", link: "" },
      { title: "From B", audio_url: "https://feed-b.example.com/ep1.mp3", pub_date: Time.new(2026, 3, 28), description: "", link: "" }
    ]

    received_feeds = nil
    fake_new = proc do |feeds:, **_|
      received_feeds = feeds
      stub_rss_source(episodes)
    end

    RSSSource.stub(:new, fake_new) do
      capture_io_with_input("") do
        PodgenCLI::ExcludeCommand.new(["testpod", "--ask"], {}).run
      end
    end

    assert_equal 2, received_feeds.length
  end

  def test_rss_without_ask_falls_through_to_url_mode
    write_guidelines("language", rss: "https://feed.example.com/rss")

    # --rss without --ask should treat remaining args as URLs (existing behavior)
    _, err = capture_io do
      code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com"], {}).run
      assert_equal 2, code
    end

    assert_includes err, "Usage:"
  end

  def test_ask_no_episodes_found
    write_guidelines("language", rss: "https://feed.example.com/rss")

    RSSSource.stub(:new, stub_rss_source([])) do
      _, err = capture_io do
        code = PodgenCLI::ExcludeCommand.new(["testpod", "--rss", "feed.example.com", "--ask"], {}).run
        assert_equal 1, code
      end

      assert_includes err, "No unprocessed episodes"
    end
  end

  private

  def write_guidelines(type, rss: nil)
    sources = if rss.is_a?(Array)
      "\n## Sources\n- rss:\n" + rss.map { |u| "  - #{u}" }.join("\n")
    elsif rss
      "\n## Sources\n- rss:\n  - #{rss}"
    else
      ""
    end
    File.write(File.join(@podcast_dir, "guidelines.md"),
      "# Test\n## Format\nfoo\n## Tone\nbar\n## Type\n#{type}#{sources}")
  end

  def stub_rss_source(episodes)
    source = Object.new
    source.define_singleton_method(:fetch_episodes) do |exclude_urls: Set.new|
      episodes.reject { |ep| exclude_urls.include?(ep[:audio_url]) }
    end
    source
  end

  def capture_io_with_input(input, &block)
    old_stdin = $stdin
    $stdin = StringIO.new(input + "\n")
    capture_io(&block)
  ensure
    $stdin = old_stdin
  end
end
