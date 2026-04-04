# frozen_string_literal: true

require "x"
require_relative "../loggable"
require_relative "../retryable"

class TwitterAgent
  include Loggable
  include Retryable

  DEFAULT_TEMPLATE = "\u{1f399} {title}\n\n{site_url}"
  MAX_RETRIES = 2

  def initialize(logger: nil, skip_auth: false)
    @logger = logger
    return if skip_auth

    @client = X::Client.new(
      api_key: ENV.fetch("TWITTER_CONSUMER_KEY") { raise "TWITTER_CONSUMER_KEY not set" },
      api_key_secret: ENV.fetch("TWITTER_CONSUMER_SECRET") { raise "TWITTER_CONSUMER_SECRET not set" },
      access_token: ENV.fetch("TWITTER_ACCESS_TOKEN") { raise "TWITTER_ACCESS_TOKEN not set" },
      access_token_secret: ENV.fetch("TWITTER_ACCESS_SECRET") { raise "TWITTER_ACCESS_SECRET not set" }
    )
  end

  def post_episode(title:, description: "", site_url: "", mp3_url: "", template: nil)
    text = expand_template(template || DEFAULT_TEMPLATE, title: title, description: description, site_url: site_url, mp3_url: mp3_url)
    log("Posting tweet (#{text.length} chars): #{text.lines.first&.strip}")

    response = with_retries(max: MAX_RETRIES, label: "Twitter post") do
      @client.post("tweets", "{\"text\":#{text.to_json}}", headers: { "Content-Type" => "application/json" })
    end

    tweet_id = response["data"]&.[]("id")
    log("Tweet posted: #{tweet_id}")
    tweet_id
  end

  def expand_template(template, title:, description:, site_url:, mp3_url:)
    text = template
      .gsub("{title}", title)
      .gsub("{description}", description.to_s)
      .gsub("{site_url}", site_url.to_s)
      .gsub("{mp3_url}", mp3_url.to_s)
      .gsub("\\n", "\n")
    # Pick whichever URL is present in the text for truncation
    url_in_text = [site_url, mp3_url].find { |u| u.to_s.length > 0 && text.include?(u.to_s) }
    truncate(text, url: url_in_text.to_s)
  end

  private

  def truncate(text, url: "")
    return text if text.length <= 280

    # URLs count as 23 chars in X's t.co wrapping
    url_display_len = url.to_s.empty? ? 0 : 23
    url_actual_len = url.to_s.length
    effective_len = text.length - url_actual_len + url_display_len
    return text if effective_len <= 280

    # Truncate non-URL portion
    max_text = 280 - url_display_len - 4 # "... " + url
    text_without_url = text.sub(url.to_s, "").strip
    "#{text_without_url[0...max_text].strip}...\n#{url}"
  end
end
