# frozen_string_literal: true

require_relative "../test_helper"
require "analytics_client"

class TestAnalyticsClient < Minitest::Test
  def setup
    @original_token = ENV["CLOUDFLARE_API_TOKEN"]
    @original_account = ENV["CLOUDFLARE_ACCOUNT_ID"]
  end

  def teardown
    ENV["CLOUDFLARE_API_TOKEN"] = @original_token
    ENV["CLOUDFLARE_ACCOUNT_ID"] = @original_account
  end

  # --- configured? ---

  def test_configured_returns_true_when_both_set
    ENV["CLOUDFLARE_API_TOKEN"] = "token123"
    ENV["CLOUDFLARE_ACCOUNT_ID"] = "account456"
    client = AnalyticsClient.new

    assert client.configured?
  end

  def test_configured_returns_false_when_token_missing
    ENV.delete("CLOUDFLARE_API_TOKEN")
    ENV["CLOUDFLARE_ACCOUNT_ID"] = "account456"
    client = AnalyticsClient.new

    refute client.configured?
  end

  def test_configured_returns_false_when_account_missing
    ENV["CLOUDFLARE_API_TOKEN"] = "token123"
    ENV.delete("CLOUDFLARE_ACCOUNT_ID")
    client = AnalyticsClient.new

    refute client.configured?
  end

  def test_configured_returns_false_when_empty_token
    ENV["CLOUDFLARE_API_TOKEN"] = ""
    ENV["CLOUDFLARE_ACCOUNT_ID"] = "account456"
    client = AnalyticsClient.new

    refute client.configured?
  end

  def test_configured_returns_false_when_empty_account
    ENV["CLOUDFLARE_API_TOKEN"] = "token123"
    ENV["CLOUDFLARE_ACCOUNT_ID"] = ""
    client = AnalyticsClient.new

    refute client.configured?
  end

  # --- escape ---

  def test_escape_single_quotes
    client = AnalyticsClient.new
    assert_equal "it\\'s", client.send(:escape, "it's")
  end

  def test_escape_no_quotes
    client = AnalyticsClient.new
    assert_equal "safe string", client.send(:escape, "safe string")
  end

  def test_escape_multiple_quotes
    client = AnalyticsClient.new
    assert_equal "a\\'b\\'c", client.send(:escape, "a'b'c")
  end

  # --- parse_user_agent ---

  def test_parse_user_agent_apple_podcasts
    client = AnalyticsClient.new
    assert_equal "Apple Podcasts", client.send(:parse_user_agent, "AppleCoreMedia/1.0")
  end

  def test_parse_user_agent_overcast
    client = AnalyticsClient.new
    assert_equal "Overcast", client.send(:parse_user_agent, "Overcast/3.0")
  end

  def test_parse_user_agent_spotify
    client = AnalyticsClient.new
    assert_equal "Spotify", client.send(:parse_user_agent, "Spotify/8.0 Android/12")
  end

  def test_parse_user_agent_pocket_casts
    client = AnalyticsClient.new
    assert_equal "Pocket Casts", client.send(:parse_user_agent, "PocketCasts/1.0")
  end

  def test_parse_user_agent_podcast_addict
    client = AnalyticsClient.new
    assert_equal "Podcast Addict", client.send(:parse_user_agent, "Podcast Addict/2023.1")
  end

  def test_parse_user_agent_curl
    client = AnalyticsClient.new
    assert_equal "curl", client.send(:parse_user_agent, "curl/7.88.1")
  end

  def test_parse_user_agent_chrome
    client = AnalyticsClient.new
    assert_equal "Browser (Chrome)", client.send(:parse_user_agent, "Mozilla/5.0 Chrome/118.0")
  end

  def test_parse_user_agent_firefox
    client = AnalyticsClient.new
    assert_equal "Browser (Firefox)", client.send(:parse_user_agent, "Mozilla/5.0 Firefox/119.0")
  end

  def test_parse_user_agent_safari
    client = AnalyticsClient.new
    assert_equal "Browser (Safari)", client.send(:parse_user_agent, "Mozilla/5.0 (Macintosh) AppleWebKit/605 Safari/605")
  end

  def test_parse_user_agent_bot
    client = AnalyticsClient.new
    assert_equal "Bot", client.send(:parse_user_agent, "Googlebot/2.1")
  end

  def test_parse_user_agent_nil
    client = AnalyticsClient.new
    assert_equal "Unknown", client.send(:parse_user_agent, nil)
  end

  def test_parse_user_agent_empty
    client = AnalyticsClient.new
    assert_equal "Unknown", client.send(:parse_user_agent, "")
  end

  def test_parse_user_agent_unknown_truncated
    client = AnalyticsClient.new
    long_ua = "SomeCustomApp/1.0 (Custom; Build 12345; Platform XYZ)"
    result = client.send(:parse_user_agent, long_ua)
    assert_equal long_ua[0..30], result
  end

  def test_parse_user_agent_castbox
    client = AnalyticsClient.new
    assert_equal "CastBox", client.send(:parse_user_agent, "CastBox/7.0")
  end

  def test_parse_user_agent_castro
    client = AnalyticsClient.new
    assert_equal "Castro", client.send(:parse_user_agent, "Castro 2020.1/1234")
  end

  def test_parse_user_agent_antennapod
    client = AnalyticsClient.new
    assert_equal "AntennaPod", client.send(:parse_user_agent, "AntennaPod/2.7.0")
  end

  def test_parse_user_agent_podcasts_app
    client = AnalyticsClient.new
    assert_equal "Apple Podcasts", client.send(:parse_user_agent, "Podcasts/1630.3")
  end
end
