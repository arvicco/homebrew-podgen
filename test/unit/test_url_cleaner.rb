# frozen_string_literal: true

require_relative "../test_helper"
require "url_cleaner"

class TestUrlCleaner < Minitest::Test
  def test_strips_utm_params
    url = "https://example.com/article?utm_source=twitter&utm_medium=social&id=123"
    assert_equal "https://example.com/article?id=123", UrlCleaner.clean(url)
  end

  def test_strips_fbclid
    url = "https://example.com/page?fbclid=abc123"
    assert_equal "https://example.com/page", UrlCleaner.clean(url)
  end

  def test_strips_gclid
    url = "https://example.com/page?gclid=xyz&valid=1"
    assert_equal "https://example.com/page?valid=1", UrlCleaner.clean(url)
  end

  def test_strips_all_tracking_leaves_clean_url
    url = "https://example.com/article?utm_source=x&utm_medium=y&fbclid=z"
    assert_equal "https://example.com/article", UrlCleaner.clean(url)
  end

  def test_preserves_clean_url
    url = "https://example.com/article?page=2&sort=date"
    assert_equal url, UrlCleaner.clean(url)
  end

  def test_preserves_url_without_query
    url = "https://example.com/article"
    assert_equal url, UrlCleaner.clean(url)
  end

  def test_handles_invalid_uri
    url = "not a url at all %%"
    assert_equal url, UrlCleaner.clean(url)
  end

  def test_strips_ref_and_src
    url = "https://example.com/page?ref=homepage&src=newsletter&title=hello"
    assert_equal "https://example.com/page?title=hello", UrlCleaner.clean(url)
  end

  def test_case_insensitive_matching
    url = "https://example.com/page?UTM_SOURCE=twitter&id=1"
    assert_equal "https://example.com/page?id=1", UrlCleaner.clean(url)
  end
end
