# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Queries Cloudflare Analytics Engine for podcast download stats.
# Uses the SQL API (simpler and more capable than GraphQL for Analytics Engine).
# Requires CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID in ENV.
class AnalyticsClient
  DATASET = "podgen_downloads"

  def initialize
    @token = ENV["CLOUDFLARE_API_TOKEN"]
    @account_id = ENV["CLOUDFLARE_ACCOUNT_ID"]
  end

  def configured?
    @token && !@token.empty? && @account_id && !@account_id.empty?
  end

  # Per-episode download counts for a podcast.
  # Returns: [{ episode:, downloads: }] sorted by downloads desc
  def episode_downloads(podcast:, days: 30, limit: 100)
    sql = <<~SQL
      SELECT blob1 AS episode, SUM(double1) AS downloads
      FROM #{DATASET}
      WHERE index1 = '#{escape(podcast)}'
        AND timestamp >= NOW() - INTERVAL '#{days}' DAY
      GROUP BY episode
      ORDER BY downloads DESC
      LIMIT #{limit}
    SQL

    query(sql).map do |row|
      { episode: row["episode"], downloads: row["downloads"].to_i }
    end
  end

  # Total downloads per podcast with active days for daily average.
  # Returns: [{ podcast:, downloads:, days: }] sorted by downloads desc
  def podcast_totals(days: 30, limit: 50)
    sql = <<~SQL
      SELECT index1 AS podcast, SUM(double1) AS downloads,
             COUNT(DISTINCT toDate(timestamp)) AS active_days
      FROM #{DATASET}
      WHERE timestamp >= NOW() - INTERVAL '#{days}' DAY
      GROUP BY podcast
      ORDER BY downloads DESC
      LIMIT #{limit}
    SQL

    query(sql).map do |row|
      { podcast: row["podcast"], downloads: row["downloads"].to_i, days: row["active_days"].to_i }
    end
  end

  # Downloads grouped by user-agent (app) for a podcast.
  # Returns: [{ app:, downloads: }] sorted by downloads desc
  def app_breakdown(podcast: nil, days: 30, limit: 20)
    where = "timestamp >= NOW() - INTERVAL '#{days}' DAY"
    where += " AND index1 = '#{escape(podcast)}'" if podcast

    sql = <<~SQL
      SELECT blob2 AS user_agent, SUM(double1) AS downloads
      FROM #{DATASET}
      WHERE #{where}
      GROUP BY user_agent
      ORDER BY downloads DESC
      LIMIT #{limit}
    SQL

    query(sql).map do |row|
      { app: parse_user_agent(row["user_agent"]), downloads: row["downloads"].to_i }
    end.group_by { |r| r[:app] }
      .map { |app, rows| { app: app, downloads: rows.sum { |r| r[:downloads] } } }
      .sort_by { |r| -r[:downloads] }
  end

  # Downloads grouped by day for a podcast.
  # Returns: [{ date:, downloads: }] sorted by date desc
  def daily_breakdown(podcast: nil, days: 30, limit: 90)
    where = "timestamp >= NOW() - INTERVAL '#{days}' DAY"
    where += " AND index1 = '#{escape(podcast)}'" if podcast

    sql = <<~SQL
      SELECT toDate(timestamp) AS day, SUM(double1) AS downloads
      FROM #{DATASET}
      WHERE #{where}
      GROUP BY day
      ORDER BY day DESC
      LIMIT #{limit}
    SQL

    query(sql).map do |row|
      { date: row["day"], downloads: row["downloads"].to_i }
    end
  end

  # Downloads grouped by country for a podcast.
  # Returns: [{ country:, downloads: }] sorted by downloads desc
  def country_breakdown(podcast: nil, days: 30, limit: 50)
    where = "timestamp >= NOW() - INTERVAL '#{days}' DAY"
    where += " AND index1 = '#{escape(podcast)}'" if podcast

    sql = <<~SQL
      SELECT blob3 AS country, SUM(double1) AS downloads
      FROM #{DATASET}
      WHERE #{where}
      GROUP BY country
      ORDER BY downloads DESC
      LIMIT #{limit}
    SQL

    query(sql).map do |row|
      { country: row["country"].to_s.empty? ? "??" : row["country"], downloads: row["downloads"].to_i }
    end
  end

  private

  def query(sql)
    uri = URI("https://api.cloudflare.com/client/v4/accounts/#{@account_id}/analytics_engine/sql")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 15

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{@token}"
    req.body = sql

    response = http.request(req)

    unless response.is_a?(Net::HTTPSuccess)
      body = begin
        parsed = JSON.parse(response.body)
        errors = parsed["errors"]
        if errors.is_a?(Array) && errors.any?
          errors.map { |e| e["message"] }.join(", ")
        else
          response.body[0..200]
        end
      rescue JSON::ParserError
        response.body[0..200]
      end
      raise "Analytics API error #{response.code}: #{body}"
    end

    parsed = JSON.parse(response.body)
    parsed["data"] || []
  end

  def escape(str)
    str.gsub("'", "\\\\'")
  end

  UA_PATTERNS = [
    [/AppleCoreMedia/i, "Apple Podcasts"],
    [/Podcasts\//i, "Apple Podcasts"],
    [/Overcast\//i, "Overcast"],
    [/PocketCasts/i, "Pocket Casts"],
    [/Spotify\//i, "Spotify"],
    [/CastBox/i, "CastBox"],
    [/Castro/i, "Castro"],
    [/Podcast ?Addict/i, "Podcast Addict"],
    [/AntennaPod/i, "AntennaPod"],
    [/Downcast/i, "Downcast"],
    [/Google-Podcasts/i, "Google Podcasts"],
    [/Podkicker/i, "Podkicker"],
    [/Player FM/i, "Player FM"],
    [/Fountain/i, "Fountain"],
    [/Breez/i, "Breez"],
    [/curl\//i, "curl"],
    [/wget\//i, "wget"],
    [/facebookexternalhit/i, "Facebook"],
    [/Twitterbot/i, "Twitter"],
    [/bot|crawl|spider|slurp/i, "Bot"],
    [/Mozilla.*Chrome/i, "Browser (Chrome)"],
    [/Mozilla.*Firefox/i, "Browser (Firefox)"],
    [/Mozilla.*Safari/i, "Browser (Safari)"],
    [/Mozilla/i, "Browser"],
  ].freeze

  def parse_user_agent(ua)
    return "Unknown" if ua.nil? || ua.empty?

    UA_PATTERNS.each do |pattern, name|
      return name if ua.match?(pattern)
    end

    ua[0..30]
  end
end
