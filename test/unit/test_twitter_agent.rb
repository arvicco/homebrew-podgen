# frozen_string_literal: true

require_relative "../test_helper"
require "agents/twitter_agent"

class TestTwitterAgent < Minitest::Test
  # --- expand_template ---

  def test_expand_template_substitutes_all_variables
    agent = build_agent
    result = agent.expand_template(
      "New: {title}\n{description}\n{site_url}\n{mp3_url}",
      title: "My Episode", description: "A great show",
      site_url: "https://example.com/site/episodes/ep.html",
      mp3_url: "https://example.com/episodes/ep.mp3"
    )
    assert_equal "New: My Episode\nA great show\nhttps://example.com/site/episodes/ep.html\nhttps://example.com/episodes/ep.mp3", result
  end

  def test_expand_template_handles_escaped_newlines
    agent = build_agent
    result = agent.expand_template(
      'New: {title}\n{site_url}',
      title: "Ep 1", description: "", site_url: "https://x.com/ep.html", mp3_url: ""
    )
    assert_equal "New: Ep 1\nhttps://x.com/ep.html", result
  end

  def test_expand_template_handles_missing_description
    agent = build_agent
    result = agent.expand_template(
      "{title} - {description} {site_url}",
      title: "Test", description: nil, site_url: "https://x.com", mp3_url: ""
    )
    assert_equal "Test -  https://x.com", result
  end

  def test_expand_template_handles_empty_urls
    agent = build_agent
    result = agent.expand_template(
      "{title}",
      title: "Test", description: "", site_url: "", mp3_url: ""
    )
    assert_equal "Test", result
  end

  def test_default_template_uses_site_url
    assert_includes TwitterAgent::DEFAULT_TEMPLATE, "{site_url}"
    refute_includes TwitterAgent::DEFAULT_TEMPLATE, "{mp3_url}"
  end

  def test_expand_template_truncates_long_text
    agent = build_agent
    long_title = "A" * 300
    result = agent.expand_template(
      "{title}",
      title: long_title, description: "", site_url: "", mp3_url: ""
    )
    assert result.length <= 280
  end

  # --- post_episode (stubbed) ---

  def test_post_episode_calls_api_and_returns_tweet_id
    agent = build_agent
    mock_client = Minitest::Mock.new
    mock_client.expect(:post, { "data" => { "id" => "123456" } }, [String, String], headers: Hash)

    agent.instance_variable_set(:@client, mock_client)
    tweet_id = agent.post_episode(title: "My Ep", site_url: "https://x.com")

    assert_equal "123456", tweet_id
    mock_client.verify
  end

  private

  def build_agent
    saved = %w[TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET TWITTER_ACCESS_TOKEN TWITTER_ACCESS_SECRET].map do |k|
      [k, ENV[k] || "test-#{k}"].tap { |_, _| ENV[k] ||= "test-#{k}" }
    end
    agent = TwitterAgent.new
    saved.each { |k, v| v.start_with?("test-") ? ENV.delete(k) : ENV[k] = v }
    agent
  end
end
