# frozen_string_literal: true

require_relative "../test_helper"
require "remote_image_cache"

# Q-56 / P6-3: a URL `image:` is fetched once into the podcast's cache dir.
# The body is a synthetic PNG signature, inline: the fixture recorder is for
# API text bodies, and no test here needs a decodable image.
class TestRemoteImageCache < Minitest::Test
  PNG = "\x89PNG\r\n\x1A\n".b + ("\x00".b * 16)
  URL = "https://cdn.example.com/art/cover"

  def setup
    @dir = Dir.mktmpdir("podgen_remote_image")
    @calls = []
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_fetch_url_writes_cached_path_with_content_type_extension
    cache = build(status: 200, content_type: "image/png; charset=binary", body: PNG)

    path = cache.fetch(URL)

    assert_equal File.join(@dir, "lingq_image_#{digest(URL)}.png"), path
    assert_equal PNG, File.binread(path)
    assert_equal [URL], @calls
  end

  def test_fetch_jpeg_content_type_uses_jpg_extension
    path = build(status: 200, content_type: "image/jpeg", body: PNG).fetch(URL)

    assert_equal ".jpg", File.extname(path)
  end

  def test_fetch_without_content_type_uses_url_extension
    url = "https://cdn.example.com/art/cover.webp?v=2"
    path = build(status: 200, content_type: nil, body: PNG).fetch(url)

    assert_equal ".webp", File.extname(path)
  end

  def test_fetch_reuses_cached_file_without_refetching
    cache = build(status: 200, content_type: "image/png", body: PNG)

    first = cache.fetch(URL)
    second = cache.fetch(URL)

    assert_equal first, second
    assert_equal 1, @calls.length
  end

  def test_fetch_different_url_is_fetched_separately
    cache = build(status: 200, content_type: "image/png", body: PNG)

    a = cache.fetch(URL)
    b = cache.fetch("#{URL}-v2")

    refute_equal a, b
    assert_equal 2, @calls.length
  end

  def test_fetch_http_error_raises_without_body
    body = "<html>#{"secret page body " * 50}</html>"
    cache = build(status: 404, content_type: "text/html", body: body)

    err = assert_raises(RemoteImageCache::FetchError) { cache.fetch(URL) }

    assert_includes err.message, "HTTP 404"
    assert_includes err.message, URL
    refute_includes err.message, "secret page body"
    assert_empty Dir.children(@dir)
  end

  def test_fetch_non_image_content_type_raises
    cache = build(status: 200, content_type: "text/html", body: "<html>oops</html>")

    err = assert_raises(RemoteImageCache::FetchError) { cache.fetch(URL) }

    assert_includes err.message, "text/html"
    refute_includes err.message, "oops"
  end

  def test_fetch_empty_body_raises
    cache = build(status: 200, content_type: "image/png", body: "")

    assert_raises(RemoteImageCache::FetchError) { cache.fetch(URL) }
    assert_empty Dir.children(@dir)
  end

  def test_fetch_unknown_type_and_no_url_extension_raises
    cache = build(status: 200, content_type: nil, body: PNG)

    assert_raises(RemoteImageCache::FetchError) { cache.fetch(URL) }
  end

  # W3: a temp file left by a killed write must never be taken for the image.
  def test_fetch_ignores_leftover_temp_file
    File.binwrite(File.join(@dir, "lingq_image_#{digest(URL)}.png.tmp.123.abcd"), "trunc")
    cache = build(status: 200, content_type: "image/png", body: PNG)

    path = cache.fetch(URL)

    assert_equal File.join(@dir, "lingq_image_#{digest(URL)}.png"), path
    assert_equal 1, @calls.length
  end

  # Glob metacharacters in the podcast path must not act as patterns.
  def test_fetch_reuses_cache_under_dir_with_glob_metacharacters
    dir = File.join(@dir, "pod[x]{a,b}*")
    calls = []
    fetcher = ->(url) { (calls << url) && {status: 200, content_type: "image/png", body: PNG} }
    cache = RemoteImageCache.new(cache_dir: dir, fetcher: fetcher)

    first = cache.fetch(URL)
    second = cache.fetch(URL)

    assert_equal File.join(dir, "lingq_image_#{digest(URL)}.png"), second
    assert_equal first, second
    assert_equal 1, calls.length
  end

  # N5: a signed URL's query (token) never reaches an error message.
  def test_fetch_error_message_strips_query_string
    url = "#{URL}.png?X-Amz-Signature=SECRETTOKEN&x=1"
    cache = build(status: 403, content_type: "text/html", body: "denied")

    err = assert_raises(RemoteImageCache::FetchError) { cache.fetch(url) }

    assert_includes err.message, "#{URL}.png"
    refute_includes err.message, "SECRETTOKEN"
  end

  def test_redact_strips_query_and_fragment
    assert_equal "https://a.example/x.png", RemoteImageCache.redact("https://a.example/x.png?sig=abc#frag")
    assert_equal "https://a.example/x.png", RemoteImageCache.redact("https://a.example/x.png")
  end

  # ---------- default network path (W4), Net::HTTP stubbed at .start ----------

  # consumed counts chunks pulled off the "socket"; #body mirrors
  # Net::HTTPResponse#reading_body, which buffers any unread body after the
  # request block returns.
  FakeResponse = Struct.new(:code, :headers, :chunks, :reads, :consumed) do
    def [](key) = headers[key.downcase]

    def read_body
      self.reads = (reads || 0) + 1
      self.consumed ||= 0
      chunks.each { |c| (self.consumed += 1) && yield(c) }
    end

    def body
      read_body { |_c| } unless reads
    end
  end

  def test_http_fetch_success_returns_status_type_and_binary_body
    res = ok_response([PNG[0, 10], PNG[10..]], "content-length" => PNG.bytesize.to_s)
    result, requests = with_http([res]) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a.png") }

    assert_equal({status: 200, content_type: "image/png", body: PNG}, result)
    assert_equal Encoding::BINARY, result[:body].encoding
    assert_equal [["cdn.example.com", 443, true, "/a.png"]], requests
  end

  def test_http_fetch_follows_relative_redirect
    redirect = FakeResponse.new("302", {"location" => "/img/b.png"}, [])
    result, requests = with_http([redirect, ok_response([PNG])]) do |cache|
      cache.send(:http_fetch, "https://cdn.example.com/art/a?x=1")
    end

    assert_equal PNG, result[:body]
    assert_equal ["/art/a?x=1", "/img/b.png"], requests.map(&:last)
    assert_equal ["cdn.example.com"] * 2, requests.map(&:first)
  end

  def test_http_fetch_follows_absolute_redirect_to_other_host
    redirect = FakeResponse.new("301", {"location" => "https://img.example.net/c.png"}, [])
    result, requests = with_http([redirect, ok_response([PNG])]) do |cache|
      cache.send(:http_fetch, "https://cdn.example.com/a")
    end

    assert_equal 200, result[:status]
    assert_equal "img.example.net", requests.last.first
  end

  def test_http_fetch_stops_after_max_redirects
    loops = Array.new(RemoteImageCache::MAX_REDIRECTS + 2) { FakeResponse.new("302", {"location" => "/again"}, []) }
    err = assert_raises(RemoteImageCache::FetchError) do
      with_http(loops) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a") }
    end

    assert_includes err.message, "too many redirects"
    assert_equal RemoteImageCache::MAX_REDIRECTS + 1, @http_requests.length
  end

  def test_http_fetch_redirect_without_location_raises
    redirect = FakeResponse.new("302", {}, [])
    err = assert_raises(RemoteImageCache::FetchError) do
      with_http([redirect]) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a") }
    end

    assert_includes err.message, "Location"
  end

  def test_http_fetch_refuses_https_to_http_downgrade
    redirect = FakeResponse.new("302", {"location" => "http://cdn.example.com/a.png"}, [])
    err = assert_raises(RemoteImageCache::FetchError) do
      with_http([redirect]) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a") }
    end

    assert_includes err.message, "downgrade"
    assert_equal 1, @http_requests.length
  end

  def test_http_fetch_refuses_non_http_scheme
    err = assert_raises(RemoteImageCache::FetchError) do
      with_http([]) { |cache| cache.send(:http_fetch, "ftp://cdn.example.com/a.png") }
    end

    assert_includes err.message, "http(s)"
    assert_empty @http_requests
  end

  def test_http_fetch_retries_retriable_status
    busy = FakeResponse.new("503", {}, ["busy"])
    result, requests = with_http([busy, ok_response([PNG])]) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a.png") }

    assert_equal PNG, result[:body]
    assert_equal 2, requests.length
    assert_nil busy.reads, "a retriable response body is not read"
  end

  def test_http_fetch_non_success_body_is_discarded
    missing = FakeResponse.new("404", {"content-type" => "text/html"}, ["<html>secret</html>"])
    result, = with_http([missing]) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a.png") }

    assert_equal({status: 404, content_type: "text/html", body: ""}, result)
  end

  # CRPR round 2: Net::HTTP buffers an unread body after the request block,
  # so non-2xx and redirect bodies are drained under the cap, not left unread.
  def test_http_fetch_non_success_body_drain_stops_at_cap
    missing = FakeResponse.new("404", {"content-type" => "text/html"}, Array.new(5) { "z" * 40 })
    err = assert_raises(RemoteImageCache::FetchError) do
      with_http([missing], max_bytes: 100) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a.png") }
    end

    assert_includes err.message, "HTTP 404"
    assert_equal 3, missing.consumed, "draining stops at the first chunk past the cap"
  end

  def test_http_fetch_redirect_body_drain_stops_at_cap
    redirect = FakeResponse.new("302", {"location" => "/b.png"}, Array.new(5) { "z" * 40 })
    assert_raises(RemoteImageCache::FetchError) do
      with_http([redirect, ok_response([PNG])], max_bytes: 100) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a.png") }
    end

    assert_equal 3, redirect.consumed
    assert_equal 1, @http_requests.length
  end

  def test_http_fetch_content_length_over_cap_raises_before_reading
    big = ok_response(["x" * 10], "content-length" => "101")
    err = assert_raises(RemoteImageCache::FetchError) do
      with_http([big], max_bytes: 100) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a.png?sig=SECRET") }
    end

    assert_includes err.message, "over"
    refute_includes err.message, "SECRET"
    assert_nil big.reads
  end

  def test_http_fetch_streamed_body_over_cap_raises_mid_stream
    consumed = 0
    big = ok_response([])
    big.define_singleton_method(:read_body) do |&blk|
      5.times { (consumed += 1) && blk.call("y" * 40) }
    end

    assert_raises(RemoteImageCache::FetchError) do
      with_http([big], max_bytes: 100) { |cache| cache.send(:http_fetch, "https://cdn.example.com/a.png") }
    end
    assert_equal 3, consumed, "reading stops at the first chunk past the cap"
  end

  def test_fetch_with_default_fetcher_writes_cached_file
    path, = with_http([ok_response([PNG])]) { |cache| cache.fetch("https://cdn.example.com/a.png") }

    assert_equal PNG, File.binread(path)
    assert_equal ".png", File.extname(path)
  end

  private

  def ok_response(chunks, headers = {})
    FakeResponse.new("200", {"content-type" => "image/png"}.merge(headers), chunks)
  end

  # Runs the block with Net::HTTP.start stubbed to serve +responses+ in order.
  # Returns [block result, requests as [host, port, use_ssl, request_uri]].
  def with_http(responses, max_bytes: RemoteImageCache::MAX_BYTES)
    queue = responses.dup
    @http_requests = requests = []
    start = ->(host, port, use_ssl: false, **_opts, &blk) {
      http = Object.new
      http.define_singleton_method(:request) do |req, &rblk|
        requests << [host, port, use_ssl, req.path]
        res = queue.shift or raise "unexpected request #{req.path}"
        rblk.call(res)
        res.body # as Net::HTTPResponse#reading_body does
        res
      end
      blk.call(http)
    }
    cache = RemoteImageCache.new(cache_dir: @dir, max_bytes: max_bytes)
    cache.define_singleton_method(:sleep) { |_s| nil }
    result = Net::HTTP.stub(:start, start) { yield cache }
    [result, requests]
  end

  def build(status:, content_type:, body:)
    calls = @calls
    fetcher = ->(url) {
      calls << url
      {status: status, content_type: content_type, body: body}
    }
    RemoteImageCache.new(cache_dir: @dir, fetcher: fetcher)
  end

  def digest(url)
    require "digest"
    Digest::SHA256.hexdigest(url)[0, 12]
  end
end
