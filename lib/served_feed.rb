# frozen_string_literal: true

require "net/http"
require "uri"
require "date"
require "time"
require "rexml/document"
require_relative "http_retryable"

# Reads back the feed subscribers actually get (`base_url/feed.xml`, P7-2):
# the date of its newest <item> pubDate. `podgen status` compares it with the
# newest local episode, so a publish that "succeeded" without changing the
# served feed (stale CDN, wrong base_url, bucket mismatch) still trips a WARN.
# The fetcher is injectable; tests never touch the network. Host: the
# podcast's base_url (SourceRegistry "served_feed").
class ServedFeed
  include HttpRetryable

  class StatusError < StandardError; end

  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10
  RETRIES = 1

  def initialize(fetcher: nil)
    @fetcher = fetcher || method(:http_get)
  end

  # Date of the newest parseable item pubDate; nil when the feed has none.
  # Network errors are retried once (then raised wrapped, original as
  # #cause); a non-2xx answer raises StatusError ("HTTP 404"), not retried.
  def newest_date(url)
    body = with_http_retries("served feed", max: RETRIES) { @fetcher.call(url) }
    dates = REXML::XPath.match(REXML::Document.new(body), "//item/pubDate").filter_map do |node|
      Time.rfc2822(node.text.to_s.strip).to_date
    rescue ArgumentError
      nil
    end
    dates.max
  end

  private

  def http_get(url)
    uri = URI(url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.get(uri.request_uri) }
    code = response.code.to_i
    raise RetriableError, "HTTP #{code}" if RETRIABLE_CODES.include?(code)
    raise StatusError, "HTTP #{code}" unless (200..299).cover?(code)

    response.body
  end

  # Status output is one line per podcast; retries stay silent.
  def retry_log(_message) = nil
end
