# frozen_string_literal: true

require_relative "../test_helper"
require "http_downloader"
require "tmpdir"

class TestHttpDownloader < Minitest::Test
  def setup
    @downloader = HttpDownloader.new
    @downloader.define_singleton_method(:sleep) { |_| }
    @dest = File.join(Dir.tmpdir, "test_http_downloader_#{Process.pid}.bin")
  end

  def teardown
    File.delete(@dest) if File.exist?(@dest)
  end

  # --- Unit tests (no network) ---

  def test_raises_on_empty_file
    downloader = build_downloader
    downloader.define_singleton_method(:fetch) { |_uri, path, _r = nil| File.write(path, "") }

    assert_raises(RuntimeError) { downloader.download("http://example.com/empty", @dest) }
  end

  def test_write_body_enforces_size_limit
    downloader = HttpDownloader.new(max_size: 10)

    response = Object.new
    response.define_singleton_method(:read_body) { |&block| block.call("x" * 20) }

    err = assert_raises(RuntimeError) do
      downloader.send(:write_body, response, @dest, URI.parse("http://example.com/big"))
    end
    assert_match(/MB limit/, err.message)
  end

  def test_follow_redirect_raises_when_exhausted
    response = Object.new
    response.define_singleton_method(:[]) { |_key| "http://example.com/next" }

    err = assert_raises(RuntimeError) do
      @downloader.send(:follow_redirect, response, URI.parse("http://example.com/a"), @dest, 0)
    end
    assert_match(/Too many redirects/, err.message)
  end

  def test_follow_redirect_resolves_relative_location
    response = Object.new
    response.define_singleton_method(:[]) { |_key| "/relative/path" }

    fetched_uri = nil
    @downloader.define_singleton_method(:fetch) { |uri, _path, _r = nil| fetched_uri = uri }

    @downloader.send(:follow_redirect, response, URI.parse("http://example.com/original"), @dest, 2)
    assert_equal "/relative/path", fetched_uri.path
    assert_equal "example.com", fetched_uri.host
  end

  def test_default_constants
    assert_equal 3, HttpDownloader::MAX_RETRIES
    assert_equal 3, HttpDownloader::MAX_REDIRECTS
    assert_equal 200 * 1024 * 1024, HttpDownloader::MAX_SIZE
  end

  def test_includes_loggable_and_retryable
    assert HttpDownloader.include?(Loggable)
    assert HttpDownloader.include?(Retryable)
  end

  def test_download_retries_on_failure
    attempts = 0
    downloader = build_downloader
    downloader.define_singleton_method(:fetch) do |_uri, path, _r = nil|
      attempts += 1
      raise "connection reset" if attempts < 3
      File.write(path, "ok")
    end

    result = downloader.download("http://example.com/retry", @dest)
    assert_equal @dest, result
    assert_equal 3, attempts
    assert_equal "ok", File.read(@dest)
  end

  def test_download_raises_after_max_retries
    downloader = build_downloader
    downloader.define_singleton_method(:fetch) { |_uri, _path, _r = nil| raise "always fails" }

    err = assert_raises(RuntimeError) { downloader.download("http://example.com/fail", @dest) }
    assert_match(/failed after/, err.message)
  end

  private

  def build_downloader
    d = HttpDownloader.new
    d.define_singleton_method(:sleep) { |_| }
    d
  end
end
