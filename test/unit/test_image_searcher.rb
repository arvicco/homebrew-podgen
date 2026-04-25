# frozen_string_literal: true

require_relative "../test_helper"
require "image_searcher"

class TestImageSearcher < Minitest::Test
  def test_search_returns_survivors_above_min_size
    searcher = ImageSearcher.new
    urls = ["https://a.com/big.jpg", "https://b.com/small.jpg", "https://c.com/medium.jpg"]
    searcher.stub :fetch_urls, urls do
      searcher.stub :download, ->(url, path) {
        bytes = case url
                when /big/    then 50_000
                when /small/  then 1_000
                when /medium/ then 30_000
                end
        File.binwrite(path, "x" * bytes)
        bytes
      } do
        results = searcher.search("test", count: 3, min_bytes: 20_000)
        assert_equal 2, results.length
        urls_kept = results.map { |r| r[:url] }
        assert_includes urls_kept, "https://a.com/big.jpg"
        assert_includes urls_kept, "https://c.com/medium.jpg"
        refute_includes urls_kept, "https://b.com/small.jpg"
        assert results.all? { |r| r[:bytes] >= 20_000 }
        assert results.all? { |r| File.exist?(r[:path]) }
      end
    end
  ensure
    cleanup_survivors
  end

  def test_search_returns_empty_when_no_urls_found
    searcher = ImageSearcher.new
    searcher.stub :fetch_urls, [] do
      results = searcher.search("nothing", count: 5, min_bytes: 10_000)
      assert_equal [], results
    end
  end

  def test_search_handles_download_failure_gracefully
    searcher = ImageSearcher.new
    searcher.stub :fetch_urls, ["https://a.com/x.jpg", "https://b.com/y.jpg"] do
      searcher.stub :download, ->(url, _path) {
        url.include?("a.com") ? nil : (File.binwrite(_path, "x" * 50_000); 50_000)
      } do
        results = searcher.search("test", count: 2, min_bytes: 20_000)
        assert_equal 1, results.length
        assert_equal "https://b.com/y.jpg", results.first[:url]
      end
    end
  ensure
    cleanup_survivors
  end

  def test_search_deletes_undersized_downloads
    searcher = ImageSearcher.new
    captured_paths = []
    searcher.stub :fetch_urls, ["https://a.com/tiny.jpg"] do
      searcher.stub :download, ->(_url, path) {
        File.binwrite(path, "x" * 500)
        captured_paths << path
        500
      } do
        searcher.search("test", count: 1, min_bytes: 10_000)
      end
    end
    refute captured_paths.empty?, "download should have been attempted"
    assert captured_paths.none? { |p| File.exist?(p) }, "undersized files should be deleted"
  end

  def test_url_ext_falls_back_to_jpg_for_unknown
    searcher = ImageSearcher.new
    assert_equal ".jpg",  searcher.send(:url_ext, "https://a.com/foo")
    assert_equal ".jpg",  searcher.send(:url_ext, "https://a.com/foo.bin")
    assert_equal ".png",  searcher.send(:url_ext, "https://a.com/foo.png")
    assert_equal ".webp", searcher.send(:url_ext, "https://a.com/foo.webp?v=1")
  end

  def test_fetch_vqd_extracts_quoted_token
    searcher = ImageSearcher.new
    body = "var x = 1; vqd='3-12345678901-90'; var y = 2;"
    fake = Struct.new(:body) { def is_a?(klass); klass == Net::HTTPSuccess; end }.new(body)
    searcher.stub :http_get, fake do
      assert_equal "3-12345678901-90", searcher.send(:fetch_vqd, "anything")
    end
  end

  def test_fetch_vqd_returns_nil_on_failure
    searcher = ImageSearcher.new
    fake = Struct.new(:body) { def is_a?(klass); false; end }.new("")
    searcher.stub :http_get, fake do
      assert_nil searcher.send(:fetch_vqd, "anything")
    end
  end

  private

  def cleanup_survivors
    # Tmp dirs are isolated per Dir.mktmpdir call; nothing global to clean.
  end
end
