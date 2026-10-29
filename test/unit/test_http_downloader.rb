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

  def test_write_body_size_abort_leaves_no_file_at_destination
    downloader = HttpDownloader.new(max_size: 10)
    response = Object.new
    response.define_singleton_method(:read_body) { |&block| 2.times { block.call("x" * 6) } }

    assert_raises(RuntimeError) do
      downloader.send(:write_body, response, @dest, URI.parse("http://example.com/big"))
    end

    refute File.exist?(@dest), "partial file must not remain at destination"
    assert_empty Dir.glob("#{@dest}.part.*"), "temp partial must be cleaned up"
  end

  def test_follow_redirect_raises_when_exhausted
    response = Object.new
    response.define_singleton_method(:[]) { |_key| "http://example.com/next" }

    err = assert_raises(RuntimeError) do
      @downloader.send(:follow_redirect, response, URI.parse("http://example.com/a"), @dest, 0)
    end
    assert_match(/Too many redirects/, err.message)
  end

  def test_fetch_follows_four_hop_redirect_chain
    # Real-world podcast CDN chains (podtrac → host → CDN → signed origin)
    # routinely exceed 3 redirects. Spreaker episodes go through 4. We test
    # `fetch` directly to bypass the `download` retry layer — production
    # retries don't help here because each fresh attempt hits the same cap.
    hop = 0

    @downloader.define_singleton_method(:fetch) do |uri, path, redirects_left = HttpDownloader::MAX_REDIRECTS|
      hop += 1
      if hop <= 4
        response = Object.new
        response.define_singleton_method(:[]) { |_key| "http://example.com/hop#{hop + 1}" }
        send(:follow_redirect, response, uri, path, redirects_left)
      else
        File.write(path, "ok")
      end
    end

    @downloader.send(:fetch, URI.parse("http://example.com/start"), @dest)

    assert_equal "ok", File.read(@dest)
    assert_equal 5, hop, "Expected 4 redirects + 1 final response"
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
    assert_equal 6, HttpDownloader::MAX_REDIRECTS
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

  # Q-100 (P11-1): a 404/410 is permanent — one attempt, a typed error
  # carrying the status; every other status keeps today's retries.
  def test_download_404_makes_one_attempt_and_raises_gone
    starts = with_status_server("404") do
      err = assert_raises(HttpDownloader::Gone) { build_downloader.download("http://example.com/gone.mp3", @dest) }
      assert_equal 404, err.status
      assert_match(/HTTP 404/, err.message)
    end
    assert_equal 1, starts
  end

  def test_download_410_makes_one_attempt_and_raises_gone
    starts = with_status_server("410") do
      err = assert_raises(HttpDownloader::Gone) { build_downloader.download("http://example.com/gone.mp3", @dest) }
      assert_equal 410, err.status
    end
    assert_equal 1, starts
  end

  def test_download_403_keeps_retrying
    starts = with_status_server("403") do
      err = assert_raises(RuntimeError) { build_downloader.download("http://example.com/denied.mp3", @dest) }
      assert_match(/failed after 4 attempts: HTTP 403/, err.message)
    end
    assert_equal HttpDownloader::MAX_RETRIES + 1, starts
  end

  private

  # Stubs Net::HTTP.start with a fake connection answering every request
  # with +code+; returns how many connections were opened.
  def with_status_server(code)
    starts = 0
    klass = Net::HTTPResponse::CODE_TO_OBJ.fetch(code)
    http = Object.new
    http.define_singleton_method(:request) { |_req, &blk| blk.call(klass.new("1.1", code, "status")) }
    start = lambda do |*_a, **_k, &blk|
      starts += 1
      blk.call(http)
    end
    Net::HTTP.stub(:start, start) { yield }
    starts
  end

  def build_downloader
    d = HttpDownloader.new
    d.define_singleton_method(:sleep) { |_| }
    d
  end
end
