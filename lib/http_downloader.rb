# frozen_string_literal: true

require "net/http"
require "uri"
require_relative "loggable"
require_relative "retryable"

# Downloads files over HTTP with redirect following, size limits, and retry support.
#
# Usage:
#   downloader = HttpDownloader.new(logger: my_logger)
#   path = downloader.download(url, dest_path)
class HttpDownloader
  include Loggable
  include Retryable

  MAX_RETRIES = 3
  MAX_REDIRECTS = 6
  MAX_SIZE = 200 * 1024 * 1024 # 200 MB
  USER_AGENT = "PodcastAgent/1.0"
  # Statuses that will not change on a retry (Q-100, P11-1): one attempt.
  PERMANENT_STATUSES = [404, 410].freeze

  # The resource is gone for good (404/410); +status+ is the HTTP code.
  class Gone < StandardError
    attr_reader :status

    def initialize(status, url)
      @status = status
      super("HTTP #{status} downloading #{url}")
    end
  end

  def initialize(logger: nil, max_size: MAX_SIZE)
    @logger = logger
    @max_size = max_size
  end

  # Downloads +url+ to +path+, following redirects and retrying on failure.
  # Raises if the download fails after retries or if the file is empty.
  # Returns +path+.
  def download(url, path)
    log("Downloading: #{url}")

    gone = nil
    with_retries(max: MAX_RETRIES, on: [StandardError], label: "Download") do
      uri = URI.parse(url)
      fetch(uri, path)
    rescue Gone => e
      gone = e # permanent: leave the retry loop after one attempt
    end
    raise gone if gone

    raise "Downloaded file is empty: #{url}" unless File.size(path) > 0

    path
  end

  private

  def fetch(uri, path, redirects_left = MAX_REDIRECTS)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 15, read_timeout: 120) do |http|
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = USER_AGENT

      http.request(request) do |response|
        case response
        when Net::HTTPSuccess
          write_body(response, path, uri)
        when Net::HTTPRedirection
          follow_redirect(response, uri, path, redirects_left)
        else
          raise Gone.new(response.code.to_i, uri) if PERMANENT_STATUSES.include?(response.code.to_i)
          raise "HTTP #{response.code} downloading #{uri}"
        end
      end
    end
  end

  def write_body(response, path, uri)
    bytes = 0
    tmp = "#{path}.part.#{Process.pid}"
    begin
      File.open(tmp, "wb") do |f|
        response.read_body do |chunk|
          bytes += chunk.bytesize
          raise "Download exceeds #{@max_size / (1024 * 1024)} MB limit" if bytes > @max_size
          f.write(chunk)
        end
      end
      File.rename(tmp, path)
    ensure
      File.delete(tmp) if File.exist?(tmp)
    end
    log("Downloaded #{bytes} bytes → #{path}")
  end

  def follow_redirect(response, uri, path, redirects_left)
    raise "Too many redirects" if redirects_left <= 0
    location = response["location"]
    location = URI.join(uri.to_s, location).to_s unless location.start_with?("http")
    log("Following redirect → #{location}")
    fetch(URI.parse(location), path, redirects_left - 1)
  end
end
