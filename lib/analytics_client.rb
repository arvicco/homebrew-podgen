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

  # Total downloads per podcast.
  # Returns: [{ podcast:, downloads: }] sorted by downloads desc
  def podcast_totals(days: 30, limit: 50)
    sql = <<~SQL
      SELECT index1 AS podcast, SUM(double1) AS downloads
      FROM #{DATASET}
      WHERE timestamp >= NOW() - INTERVAL '#{days}' DAY
      GROUP BY podcast
      ORDER BY downloads DESC
      LIMIT #{limit}
    SQL

    query(sql).map do |row|
      { podcast: row["podcast"], downloads: row["downloads"].to_i }
    end
  end

  # Downloads grouped by country for a podcast.
  # Returns: [{ country:, downloads: }] sorted by downloads desc
  def country_breakdown(podcast:, days: 30, limit: 50)
    sql = <<~SQL
      SELECT blob3 AS country, SUM(double1) AS downloads
      FROM #{DATASET}
      WHERE index1 = '#{escape(podcast)}'
        AND timestamp >= NOW() - INTERVAL '#{days}' DAY
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
end
