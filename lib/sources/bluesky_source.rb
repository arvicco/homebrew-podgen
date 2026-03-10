# frozen_string_literal: true

require "httparty"
require "json"
require_relative "base_source"

class BlueskySource < BaseSource
  RESULTS_PER_TOPIC = 5
  PDS_HOST = "https://bsky.social"
  SEARCH_ENDPOINT = "/xrpc/app.bsky.feed.searchPosts"
  SESSION_ENDPOINT = "/xrpc/com.atproto.server.createSession"

  def initialize(logger: nil, **_options)
    super
    @handle = ENV["BLUESKY_HANDLE"]
    @app_password = ENV["BLUESKY_APP_PASSWORD"]
    @access_token = nil
  end

  def research(topics, exclude_urls: Set.new)
    return empty_results(topics) unless available?

    authenticate!
    super
  end

  private

  def available?
    @handle && @app_password
  end

  def authenticate!
    response = HTTParty.post(
      "#{PDS_HOST}#{SESSION_ENDPOINT}",
      headers: { "Content-Type" => "application/json" },
      body: { identifier: @handle, password: @app_password }.to_json,
      timeout: 15
    )

    unless response.success?
      error = response.parsed_response
      raise "Bluesky auth failed: #{error['message'] || response.code}"
    end

    @access_token = response.parsed_response["accessJwt"]
    log("Authenticated as #{@handle}")
  end

  def search_topic(topic, exclude_urls)
    response = request_with_retry(
      q: topic,
      limit: RESULTS_PER_TOPIC * 2,
      sort: "latest"
    )

    return [] unless response && response["posts"]

    response["posts"].filter_map do |post|
      record = post["record"] || {}
      text = record["text"].to_s.strip
      next if text.empty?

      author = post.dig("author", "handle") || "unknown"
      uri = post["uri"].to_s

      # Build web URL from AT URI: at://did:plc:xxx/app.bsky.feed.post/yyy
      post_url = at_uri_to_url(uri, author)
      next if exclude_urls.include?(post_url)

      # Use first line or first 120 chars as title
      title = text.lines.first.to_s.strip
      title = "#{title[0, 117]}..." if title.length > 120

      # Full text as summary, capped at 500 chars
      summary = text.length > 500 ? "#{text[0, 497]}..." : text

      like_count = post["likeCount"] || 0
      repost_count = post["repostCount"] || 0
      summary = "#{summary} [#{like_count} likes, #{repost_count} reposts on Bluesky]"

      {
        title: "@#{author}: #{title}",
        url: post_url,
        summary: summary
      }
    end.first(RESULTS_PER_TOPIC)
  rescue => e
    log("Failed to search Bluesky for '#{topic}': #{e.message}")
    []
  end

  def at_uri_to_url(at_uri, handle)
    # at://did:plc:abc123/app.bsky.feed.post/xyz789 → https://bsky.app/profile/handle/post/xyz789
    if at_uri.match?(%r{/app\.bsky\.feed\.post/})
      rkey = at_uri.split("/").last
      "https://bsky.app/profile/#{handle}/post/#{rkey}"
    else
      "https://bsky.app/profile/#{handle}"
    end
  end

  def request_with_retry(**params)
    with_retries(max: MAX_RETRIES, label: source_name) do
      response = HTTParty.get(
        "#{PDS_HOST}#{SEARCH_ENDPOINT}",
        query: params,
        headers: { "Authorization" => "Bearer #{@access_token}" },
        timeout: 15
      )
      raise "HTTP #{response.code} from Bluesky API" unless response.success?
      response.parsed_response
    end
  end
end
