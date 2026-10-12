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
# default goes through HttpRetryable#with_http_retries, follows http(s)
# redirects (never https->http) and streams the body under +max_bytes+.
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

  # The URL without its query string or fragment: a signed URL's token must
  # never reach a log line, a warning or a notification.
  def self.redact(url)
    url.to_s.sub(/[?#].*\z/m, "")
  end

  def initialize(cache_dir:, fetcher: nil, max_bytes: MAX_BYTES)
    @cache_dir = cache_dir
    @fetcher = fetcher || method(:http_fetch)
    @max_bytes = max_bytes
  end

  # Returns the cached file path for +url+, fetching it on first use.
  # Raises FetchError (message names the redacted URL and status, never the body).
  def fetch(url)
    stem = "#{BASENAME}_#{Digest::SHA256.hexdigest(url)[0, 12]}"
    # Real image names only: a temp file left by a killed write never matches.
    # base: keeps glob metacharacters in the podcast path literal.
    cached = Dir.glob("#{stem}{#{EXTENSIONS.values.uniq.join(",")}}", base: @cache_dir)
      .map { |name| File.join(@cache_dir, name) }.find { |p| File.size?(p) }
    return cached if cached

    shown = self.class.redact(url)
    response = @fetcher.call(url)
    status = response[:status].to_i
    raise FetchError, "HTTP #{status} fetching #{shown}" unless (200..299).cover?(status)

    body = response[:body].to_s
    raise FetchError, "empty body fetching #{shown}" if body.empty?
    raise FetchError, "image over #{@max_bytes} bytes: #{shown}" if body.bytesize > @max_bytes

    path = File.join(@cache_dir, stem + extension_for(url, response[:content_type]))
    write_atomically(path, body)
    path
  end

  private

  def extension_for(url, content_type)
    type = content_type.to_s.split(";").first.to_s.strip.downcase
    return EXTENSIONS[type] if EXTENSIONS.key?(type)
    raise FetchError, "not an image (#{type}) fetching #{self.class.redact(url)}" unless type.empty? || type == "application/octet-stream"

    ext = File.extname(URI.parse(url).path.to_s).downcase
    ext = ".jpg" if ext == ".jpeg"
    return ext if URL_EXTENSIONS.include?(ext)

    raise FetchError, "cannot tell the image type of #{self.class.redact(url)}"
  rescue URI::InvalidURIError
    raise FetchError, "invalid image URL: #{self.class.redact(url)}"
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
    uri = http_uri(url)
    secure = uri.scheme.downcase == "https"
    result = nil
    with_http_retries("Image download") do
      Net::HTTP.start(uri.host, uri.port, use_ssl: secure,
        open_timeout: 15, read_timeout: 60) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri)) { |res| result = read_response(res, url) }
      end
    end
    return result unless result.key?(:location)

    raise FetchError, "too many redirects fetching #{self.class.redact(url)}" if redirects_left <= 0
    target = URI.join(url, result[:location]).to_s
    if secure && http_uri(target).scheme.downcase == "http"
      raise FetchError, "refusing https->http downgrade redirect from #{self.class.redact(url)}"
    end
    http_fetch(target, redirects_left - 1)
  rescue URI::InvalidURIError
    raise FetchError, "invalid image URL or redirect: #{self.class.redact(url)}"
  end

  # Turns one response into the fetcher hash, streaming a success body under
  # the size cap; a redirect yields { location: }. Other bodies are drained
  # and discarded under the cap: Net::HTTPResponse#reading_body would
  # otherwise buffer an unread body in full after this block returns.
  def read_response(res, url)
    code = res.code.to_i
    raise RetriableError, "HTTP #{code} fetching #{self.class.redact(url)}" if RETRIABLE_CODES.include?(code)
    if (300..399).cover?(code)
      location = res["location"].to_s
      raise FetchError, "HTTP #{code} without a Location header fetching #{self.class.redact(url)}" if location.empty?
      drain(res, code, url)
      return {location: location}
    end
    unless (200..299).cover?(code)
      drain(res, code, url)
      return {status: code, content_type: res["content-type"], body: ""}
    end

    raise too_big(url) if res["content-length"].to_i > @max_bytes
    body = String.new(encoding: Encoding::BINARY)
    res.read_body do |chunk|
      body << chunk.b
      raise too_big(url) if body.bytesize > @max_bytes
    end
    {status: code, content_type: res["content-type"], body: body}
  end

  def drain(res, code, url)
    bytes = 0
    res.read_body do |chunk|
      bytes += chunk.bytesize
      raise FetchError, "HTTP #{code} with a body over #{@max_bytes} bytes: #{self.class.redact(url)}" if bytes > @max_bytes
    end
  end

  def http_uri(url)
    uri = URI.parse(url)
    unless %w[http https].include?(uri.scheme&.downcase) && uri.host
      raise FetchError, "image URL must be http(s): #{self.class.redact(url)}"
    end
    uri
  end

  def too_big(url)
    FetchError.new("image over #{@max_bytes} bytes: #{self.class.redact(url)}")
  end
end
