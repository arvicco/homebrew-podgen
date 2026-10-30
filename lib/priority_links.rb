# frozen_string_literal: true

require "date"
require "net/http"
require "uri"
require_relative "atomic_writer"
require_relative "yaml_loader"
require_relative "logger"
require_relative "http_retryable"

# Manages priority links for news podcasts.
# Links are stored in podcasts/<name>/links.yml and consumed on successful generation.
class PriorityLinks
  include HttpRetryable

  # A fetch that produced no page and may succeed later (5xx, 429).
  class FetchError < StandardError; end

  # A fetch that cannot succeed on retry: 4xx other than 429, a non-HTTP or
  # malformed URL, a redirect loop.
  class PermanentFetchError < FetchError; end

  # Failures reported in #dead_urls (consumed, never injected) instead of
  # staying queued.
  PERMANENT_ERRORS = [PermanentFetchError, URI::InvalidURIError].freeze

  MAX_FETCHES = 3 # the first request plus up to two redirects

  # fetcher: seam for tests — callable(URI) returning a response with
  # #code, #[]("location") and #body. Default: Net::HTTP GET through
  # HttpRetryable (P8-4).
  def initialize(path, fetcher: nil)
    @path = path
    @fetcher = fetcher || method(:http_get)
    @dead_urls = []
  end

  # URLs the last #fetch_all found permanently dead: the caller consumes
  # them with the fetched ones, without passing them to the script.
  attr_reader :dead_urls

  # Returns array of link hashes: [{ "url" => ..., "added" => ..., "note" => ... }]
  def all
    YamlLoader.load(@path, default: [])
  end

  def empty?
    all.empty?
  end

  def count
    all.length
  end

  # Add a URL. Deduplicates by URL. Returns true if added, false if duplicate.
  def add(url, note: nil)
    entries = all
    return false if entries.any? { |e| e["url"] == url }

    entry = { "url" => url, "added" => Date.today.to_s }
    entry["note"] = note if note && !note.empty?
    entries << entry
    write!(entries)
    true
  end

  # Remove a URL. Returns true if found and removed, false otherwise.
  def remove(url)
    entries = all
    before = entries.length
    entries.reject! { |e| e["url"] == url }
    return false if entries.length == before

    write!(entries)
    true
  end

  # Clear all links. Returns count of removed links.
  def clear!
    entries = all
    count = entries.length
    return 0 if count.zero?

    File.delete(@path) if File.exist?(@path)
    count
  end

  # Fetch content for all links, returning research-style findings.
  # Returns: [{ title:, url:, summary: }]
  # Includes the user's note in the summary if present.
  # Failed links are never returned (P8-4). A transient failure (timeout,
  # DNS, 5xx, 429) leaves the link queued for the next run; a permanent one
  # (PERMANENT_ERRORS) is listed in #dead_urls, after one warning, for the
  # caller to consume — a dead URL must not reach the script or its sources.
  def fetch_all(logger: nil)
    @dead_urls = []
    entries = all
    return [] if entries.empty?

    @log_target = target = logger || PodcastAgent.logger
    entries.filter_map do |entry|
      url = entry["url"]
      note = entry["note"]
      target.log("  Fetching: #{url}")

      start = Time.now
      title, summary = fetch_page_info(url)
      elapsed = (Time.now - start).round(2)
      title ||= url
      target.log("  \u2713 #{title} (#{elapsed}s)")
      summary = [note, summary].compact.reject(&:empty?).join(" — ") if note

      { title: title, url: url, summary: summary || "Priority link added by producer" }
    rescue *PERMANENT_ERRORS => e
      # skippable: a dead link is reported for consumption after one warning.
      warn_fetch(target, url, e)
      @dead_urls << url
      nil
    rescue => e
      # skippable: the link stays queued and is retried on the next run.
      warn_fetch(target, url, e)
      nil
    end
  ensure
    @log_target = nil
  end

  # Remove all links that were successfully consumed (by URL set).
  def consume!(urls)
    entries = all
    before = entries.length
    url_set = urls.to_set
    entries.reject! { |e| url_set.include?(e["url"]) }
    write!(entries) if entries.length != before
  end

  private

  def warn_fetch(target, url, error)
    line = "  Warning: #{url} (#{error.class}: #{error.message})"
    target.respond_to?(:warning) ? target.warning(line) : target.log(line)
  end

  def write!(entries)
    if entries.empty?
      AtomicWriter.delete_if_exists(@path)
    else
      AtomicWriter.write_yaml(@path, entries)
    end
  end

  # Fetch page title and meta description. Returns [title, summary] (either
  # may be nil when the page lacks it); raises on a failed fetch. Relative
  # Location headers resolve against the current URI (URI.join).
  def fetch_page_info(url)
    uri = URI.parse(url)
    MAX_FETCHES.times do
      raise PermanentFetchError, "not an HTTP URL: #{uri}" unless uri.is_a?(URI::HTTP)

      response = @fetcher.call(uri)
      code = response.code.to_i
      if (300..399).cover?(code) && response["location"]
        uri = URI.join(uri, response["location"])
        next
      end
      unless (200..299).cover?(code)
        permanent = (400..499).cover?(code) && code != 429
        raise (permanent ? PermanentFetchError : FetchError), "HTTP #{code}"
      end

      return parse_page(response.body.to_s)
    end
    raise PermanentFetchError, "too many redirects"
  end

  def parse_page(body)
    # scrub: a Latin-1 page or one stray byte must not fail the regexes.
    html = body.dup.force_encoding("UTF-8").scrub

    title = html[/<title[^>]*>([^<]+)<\/title>/i, 1]&.strip
    title = title&.gsub(/\s+/, " ")

    # Try to extract meta description
    summary = html[/<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']/i, 1]
    summary ||= html[/<meta[^>]+content=["']([^"']+)["'][^>]+name=["']description["']/i, 1]
    summary = summary&.strip&.gsub(/\s+/, " ")

    [title, summary]
  end

  # retryable: network errors and 429/5xx (HttpRetryable); the last error
  # propagates with its class on give-up.
  def http_get(uri)
    with_retries(max: 2, on: HTTP_EXCEPTIONS, label: "PriorityLinks", reraise: true) do
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 10) do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "podgen/1.0 (podcast link preview)"
        request["Accept"] = "text/html"
        http.request(request)
      end
      raise RetriableError, "HTTP #{response.code}" if RETRIABLE_CODES.include?(response.code.to_i)

      response
    end
  end

  def log(message)
    (@log_target || PodcastAgent.logger).log(message)
  end
end
