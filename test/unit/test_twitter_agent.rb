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

  # --- 402 Payment Required (P3-2): deterministic, never retried ---

  def test_post_episode_payment_required_makes_one_call_and_names_the_fix
    agent = build_agent
    client = RaisingClient.new { X::HTTPError.new(response: FakeResponse.new("402", "Payment Required", PAYMENT_BODY)) }
    agent.instance_variable_set(:@client, client)
    def agent.sleep(_) = raise("402 must not be retried")

    err = assert_raises(TwitterAgent::CreditsDepleted) { agent.post_episode(title: "Ep", site_url: "https://x.com") }

    assert_equal 1, client.calls
    assert_includes err.message, "X API credits depleted"
    assert_includes err.message, "top up in the developer console"
  end

  def test_post_episode_other_http_errors_still_retried
    agent = build_agent
    client = RaisingClient.new { X::ServiceUnavailable.new(response: FakeResponse.new("503", "Service Unavailable", "{}")) }
    agent.instance_variable_set(:@client, client)
    def agent.sleep(_) = nil

    err = assert_raises(RuntimeError) { agent.post_episode(title: "Ep", site_url: "https://x.com") }

    assert_equal TwitterAgent::MAX_RETRIES + 1, client.calls
    assert_match(/Twitter post failed after 3 attempts/, err.message)
  end

  # --- truncate (characterization: t.co counts any URL as 23 chars) ---

  def test_truncate_under_limit_unchanged
    agent = build_agent
    assert_equal "short tweet", agent.send(:truncate, "short tweet", url: "")
  end

  def test_truncate_at_exactly_280_unchanged
    agent = build_agent
    text = "a" * 280
    assert_equal text, agent.send(:truncate, text, url: "")
  end

  def test_truncate_over_280_but_within_tco_budget_unchanged
    agent = build_agent
    # 301 raw chars, but the 100-char URL counts as 23 → effective 224
    url = "https://example.com/#{"x" * 80}"
    text = "#{"a" * 200} #{url}"
    assert_equal 301, text.length
    assert_equal text, agent.send(:truncate, text, url: url)
  end

  def test_truncate_over_budget_ellipsizes_and_reappends_url
    agent = build_agent
    url = "https://example.com/a" # 21 chars, counts as 23
    text = "#{"a" * 300}\n#{url}"
    result = agent.send(:truncate, text, url: url)
    # max_text = 280 - 23 - 4 = 253 chars of non-URL text kept
    assert_equal "#{"a" * 253}...\n#{url}", result
  end

  def test_truncate_empty_url_ellipsizes_without_trailing_newline
    agent = build_agent
    result = agent.send(:truncate, "a" * 300, url: "")
    assert_equal "#{"a" * 276}...", result
    assert_equal 279, result.length
  end

  def test_truncate_nil_url_treated_as_empty
    agent = build_agent
    result = agent.send(:truncate, "a" * 300, url: nil)
    assert_equal "#{"a" * 276}...", result
  end

  private

  PAYMENT_BODY = '{"title":"Payment Required","detail":"credits depleted","type":"about:blank","status":402}'

  # Minimal Net::HTTPResponse stand-in for X::HTTPError.new(response:).
  FakeResponse = Struct.new(:code, :message, :body) do
    def [](header) = (header == "content-type") ? "application/problem+json" : nil
  end

  class RaisingClient
    attr_reader :calls

    def initialize(&error)
      @error = error
      @calls = 0
    end

    def post(*, **)
      @calls += 1
      raise @error.call
    end
  end

  def build_agent
    keys = %w[TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET TWITTER_ACCESS_TOKEN TWITTER_ACCESS_SECRET]
    saved = keys.map { |k| [k, ENV[k]] }
    keys.each { |k| ENV[k] ||= "test-#{k}" }
    TwitterAgent.new
  ensure
    saved&.each { |k, v| v ? ENV[k] = v : ENV.delete(k) }
  end
end
