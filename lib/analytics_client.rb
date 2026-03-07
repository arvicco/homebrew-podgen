# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

# Queries Cloudflare Analytics Engine for podcast download stats.
# Requires CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID in ENV.
class AnalyticsClient
  ENDPOINT = "https://api.cloudflare.com/client/v4/graphql"
  DATASET = "podgen_downloads"

  def initialize
    @token = ENV["CLOUDFLARE_API_TOKEN"]
    @account_id = ENV["CLOUDFLARE_ACCOUNT_ID"]
  end

  def configured?
    @token && !@token.empty? && @account_id && !@account_id.empty?
  end

  # Returns per-episode download counts for a podcast.
  # Options:
  #   podcast: podcast name (matches URL path segment)
  #   days: lookback period (default 30)
  #   limit: max results (default 100)
  # Returns: [{ episode:, downloads:, countries: [] }] sorted by downloads desc
  def episode_downloads(podcast:, days: 30, limit: 100)
    since = (Date.today - days).strftime("%Y-%m-%dT00:00:00Z")

    query = <<~GQL
      query {
        viewer {
          accounts(filter: { accountTag: "#{@account_id}" }) {
            #{DATASET}(
              filter: {
                datetime_geq: "#{since}"
                AND: [{ index1: "#{podcast}" }]
              }
              limit: #{limit}
              orderBy: [sum_double1_DESC]
            ) {
              sum { double1 }
              dimensions { blob1 }
            }
          }
        }
      }
    GQL

    data = request(query)
    rows = dig_rows(data)
    rows.map do |row|
      {
        episode: row.dig("dimensions", "blob1") || "unknown",
        downloads: (row.dig("sum", "double1") || 0).to_i
      }
    end
  end

  # Returns total downloads per podcast.
  # Returns: [{ podcast:, downloads: }] sorted by downloads desc
  def podcast_totals(days: 30, limit: 50)
    since = (Date.today - days).strftime("%Y-%m-%dT00:00:00Z")

    query = <<~GQL
      query {
        viewer {
          accounts(filter: { accountTag: "#{@account_id}" }) {
            #{DATASET}(
              filter: { datetime_geq: "#{since}" }
              limit: #{limit}
              orderBy: [sum_double1_DESC]
            ) {
              sum { double1 }
              dimensions { index1 }
            }
          }
        }
      }
    GQL

    data = request(query)
    rows = dig_rows(data)
    rows.map do |row|
      {
        podcast: row.dig("dimensions", "index1") || "unknown",
        downloads: (row.dig("sum", "double1") || 0).to_i
      }
    end
  end

  # Returns downloads grouped by country for a podcast.
  # Returns: [{ country:, downloads: }] sorted by downloads desc
  def country_breakdown(podcast:, days: 30, limit: 50)
    since = (Date.today - days).strftime("%Y-%m-%dT00:00:00Z")

    query = <<~GQL
      query {
        viewer {
          accounts(filter: { accountTag: "#{@account_id}" }) {
            #{DATASET}(
              filter: {
                datetime_geq: "#{since}"
                AND: [{ index1: "#{podcast}" }]
              }
              limit: #{limit}
              orderBy: [sum_double1_DESC]
            ) {
              sum { double1 }
              dimensions { blob3 }
            }
          }
        }
      }
    GQL

    data = request(query)
    rows = dig_rows(data)
    rows.map do |row|
      {
        country: row.dig("dimensions", "blob3") || "??",
        downloads: (row.dig("sum", "double1") || 0).to_i
      }
    end
  end

  private

  def request(query)
    uri = URI(ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 15

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{@token}"
    req["Content-Type"] = "application/json"
    req.body = { query: query }.to_json

    response = http.request(req)

    unless response.is_a?(Net::HTTPSuccess)
      raise "Analytics API error #{response.code}: #{response.body[0..200]}"
    end

    parsed = JSON.parse(response.body)

    if parsed["errors"]&.any?
      messages = parsed["errors"].map { |e| e["message"] }
      if messages.any? { |m| m.include?("unknown field") }
        raise "No analytics data yet. The dataset appears in GraphQL after the first download is recorded (may take a few minutes)."
      end
      raise "Analytics API error: #{messages.join(', ')}"
    end

    parsed
  end

  def dig_rows(data)
    accounts = data.dig("data", "viewer", "accounts")
    return [] unless accounts&.first

    accounts.first[DATASET] || []
  end
end
