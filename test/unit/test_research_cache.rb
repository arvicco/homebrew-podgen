# frozen_string_literal: true

require_relative "../test_helper"
require "research_cache"

class TestResearchCache < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_cache_test")
    @cache = ResearchCache.new(@tmpdir)
    @topics = ["AI tools", "Ruby updates"]
    @results = [
      { topic: "AI tools", findings: [{ title: "Test", url: "https://example.com", summary: "Summary" }] }
    ]
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_cache_miss_returns_nil
    assert_nil @cache.get("exa", @topics)
  end

  def test_cache_hit_returns_data
    @cache.set("exa", @topics, @results)
    cached = @cache.get("exa", @topics)
    refute_nil cached
    assert_equal @results.length, cached.length
  end

  def test_cache_expired_returns_nil
    @cache.set("exa", @topics, @results)

    # Backdate the cache file to 25 hours ago
    path = cache_file_path("exa", @topics)
    old_time = Time.now - (25 * 3600)
    File.utime(old_time, old_time, path)

    assert_nil @cache.get("exa", @topics)
  end

  def test_corrupted_cache_treated_as_miss
    path = cache_file_path("exa", @topics)
    File.write(path, "{{not: valid: yaml: [[[")

    assert_nil @cache.get("exa", @topics)
  end

  def test_atomic_write_no_temp_file_left
    @cache.set("exa", @topics, @results)

    tmp_files = Dir.glob(File.join(@tmpdir, "*.tmp.*"))
    assert_empty tmp_files, "Temp files should be cleaned up"
  end

  def test_prune_deletes_expired_only
    @cache.set("exa", @topics, @results)
    @cache.set("hn", ["Bitcoin"], [{ topic: "Bitcoin", findings: [] }])

    # Backdate only the first one
    path = cache_file_path("exa", @topics)
    old_time = Time.now - (25 * 3600)
    File.utime(old_time, old_time, path)

    @cache.prune!

    assert_nil @cache.get("exa", @topics), "Expired entry should be pruned"
    refute_nil @cache.get("hn", ["Bitcoin"]), "Fresh entry should survive"
  end

  def test_cache_key_is_order_independent
    topics_a = ["Ruby", "AI"]
    topics_b = ["AI", "Ruby"]

    @cache.set("exa", topics_a, @results)
    cached = @cache.get("exa", topics_b)
    refute_nil cached, "Cache key should be order-independent"
  end

  def test_different_sources_have_different_keys
    @cache.set("exa", @topics, @results)
    assert_nil @cache.get("hn", @topics), "Different source should miss"
  end

  private

  def cache_file_path(source, topics)
    key = Digest::SHA256.hexdigest("#{source}:#{topics.sort.join(',')}")
    File.join(@tmpdir, "#{key}.yml")
  end
end
