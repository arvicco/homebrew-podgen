# frozen_string_literal: true

require "digest"
require "fileutils"
require "net/http"
require "securerandom"
require "uri"
require_relative "http_retryable"

# Fetches an image URL once into a cache directory and returns the local
# path (Q-56: a LingQ `image:` given as a URL). The cached name carries a
# digest of the URL, so changing the URL in guidelines fetches the new image
# instead of reusing a stale one.
#
# The network sits behind an injectable +fetcher+: a callable taking the URL
# and returning { status:, content_type:, body: }. Tests inject a fake; the
# default goes through HttpRetryable#with_http_retries.
class RemoteImageCache
  include HttpRetryable

  class FetchError < StandardError; end

  BASENAME = "lingq_image"
  MAX_REDIRECTS = 5
  MAX_BYTES = 20 * 1024 * 1024
  EXTENSIONS = {
    "image/png" => ".png", "image/jpeg" => ".jpg", "image/jpg" => ".jpg",
    "image/webp" => ".webp", "image/gif" => ".gif"
  }.freeze
  URL_EXTENSIONS = %w[.png .jpg .jpeg .webp .gif].freeze

  def initialize(cache_dir:, fetcher: nil)
    @cache_dir = cache_dir
    @fetcher = fetcher || method(:http_fetch)
  end

  # Returns the cached file path for +url+, fetching it on first use.
  # Raises FetchError (message names the URL and status, never the body).
  def fetch(url)
    stem = "#{BASENAME}_#{Digest::SHA256.hexdigest(url)[0, 12]}"
    cached = Dir.glob(File.join(@cache_dir, "#{stem}.*")).find { |p| File.size?(p) }
    return cached if cached

    response = @fetcher.call(url)
    status = response[:status].to_i
    raise FetchError, "HTTP #{status} fetching #{url}" unless (200..299).cover?(status)

    body = response[:body].to_s
    raise FetchError, "empty body fetching #{url}" if body.empty?
    raise FetchError, "image over #{MAX_BYTES / (1024 * 1024)} MB: #{url}" if body.bytesize > MAX_BYTES

    path = File.join(@cache_dir, stem + extension_for(url, response[:content_type]))
    write_atomically(path, body)
    path
  end

  private

  def extension_for(url, content_type)
    type = content_type.to_s.split(";").first.to_s.strip.downcase
    return EXTENSIONS[type] if EXTENSIONS.key?(type)
    raise FetchError, "not an image (#{type}) fetching #{url}" unless type.empty? || type == "application/octet-stream"

    ext = File.extname(URI.parse(url).path.to_s).downcase
    ext = ".jpg" if ext == ".jpeg"
    return ext if URL_EXTENSIONS.include?(ext)

    raise FetchError, "cannot tell the image type of #{url}"
  rescue URI::InvalidURIError
    raise FetchError, "invalid image URL: #{url}"
  end

  def write_atomically(path, body)
    FileUtils.mkdir_p(@cache_dir)
    tmp = "#{path}.tmp.#{Process.pid}.#{SecureRandom.hex(4)}"
    File.binwrite(tmp, body)
    File.rename(tmp, path)
  ensure
    File.delete(tmp) if tmp && File.exist?(tmp)
  end

  def http_fetch(url, redirects_left = MAX_REDIRECTS)
    uri = URI.parse(url)
    response = with_http_retries("Image download") do
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: 15, read_timeout: 60) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri))
      end
      raise RetriableError, "HTTP #{res.code} fetching #{url}" if RETRIABLE_CODES.include?(res.code.to_i)
      res
    end

    if response.is_a?(Net::HTTPRedirection)
      raise FetchError, "too many redirects fetching #{url}" if redirects_left <= 0
      return http_fetch(URI.join(url, response["location"]).to_s, redirects_left - 1)
    end

    {status: response.code.to_i, content_type: response["content-type"], body: response.body}
  end
end
