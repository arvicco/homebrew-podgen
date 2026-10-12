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

  private

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
