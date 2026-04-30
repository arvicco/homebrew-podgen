# frozen_string_literal: true

require_relative "../test_helper"
require "youtube_batch"

class TestYoutubeBatch < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_yt_batch")
    @cursor = File.join(@tmpdir, "cursor.yml")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # ── priority mode ──

  def test_priority_picks_first_pod_with_pending
    batch = YoutubeBatch.new(
      podcasts: %w[pod_a pod_b pod_c],
      mode: :priority,
      cursor_path: @cursor,
      pending_lookup: ->(pod) { { "pod_a" => 0, "pod_b" => 2, "pod_c" => 5 }[pod] }
    )
    assert_equal "pod_b", batch.next_podcast
  end

  def test_priority_picks_first_when_all_have_pending
    batch = YoutubeBatch.new(
      podcasts: %w[pod_a pod_b],
      mode: :priority,
      cursor_path: @cursor,
      pending_lookup: ->(_) { 3 }
    )
    assert_equal "pod_a", batch.next_podcast
  end

  def test_returns_nil_when_all_caught_up
    batch = YoutubeBatch.new(
      podcasts: %w[pod_a pod_b],
      mode: :priority,
      cursor_path: @cursor,
      pending_lookup: ->(_) { 0 }
    )
    assert_nil batch.next_podcast
  end

  def test_priority_does_not_persist_cursor
    batch = YoutubeBatch.new(
      podcasts: %w[pod_a pod_b],
      mode: :priority,
      cursor_path: @cursor,
      pending_lookup: ->(pod) { pod == "pod_b" ? 1 : 0 }
    )
    batch.next_podcast
    refute File.exist?(@cursor), "priority mode should not write cursor"
  end

  # ── round-robin mode ──

  def test_round_robin_first_call_picks_first_pod
    batch = YoutubeBatch.new(
      podcasts: %w[pod_a pod_b pod_c],
      mode: :round_robin,
      cursor_path: @cursor,
      pending_lookup: ->(_) { 1 }
    )
    assert_equal "pod_a", batch.next_podcast
  end

  def test_round_robin_advances_cursor_across_calls
    pods = %w[pod_a pod_b pod_c]
    lookup = ->(_) { 1 }
    seen = []
    3.times do
      batch = YoutubeBatch.new(podcasts: pods, mode: :round_robin, cursor_path: @cursor, pending_lookup: lookup)
      seen << batch.next_podcast
    end
    assert_equal %w[pod_a pod_b pod_c], seen
  end

  def test_round_robin_wraps_around
    pods = %w[pod_a pod_b]
    lookup = ->(_) { 1 }
    seen = []
    4.times do
      batch = YoutubeBatch.new(podcasts: pods, mode: :round_robin, cursor_path: @cursor, pending_lookup: lookup)
      seen << batch.next_podcast
    end
    assert_equal %w[pod_a pod_b pod_a pod_b], seen
  end

  def test_round_robin_skips_caught_up_pods
    pending = { "pod_a" => 1, "pod_b" => 0, "pod_c" => 1 }
    lookup = ->(pod) { pending[pod] }
    seen = []
    3.times do
      batch = YoutubeBatch.new(podcasts: %w[pod_a pod_b pod_c], mode: :round_robin, cursor_path: @cursor, pending_lookup: lookup)
      seen << batch.next_podcast
    end
    assert_equal %w[pod_a pod_c pod_a], seen, "should skip pod_b which has 0 pending"
  end

  def test_round_robin_returns_nil_when_all_caught_up
    batch = YoutubeBatch.new(
      podcasts: %w[pod_a pod_b],
      mode: :round_robin,
      cursor_path: @cursor,
      pending_lookup: ->(_) { 0 }
    )
    assert_nil batch.next_podcast
  end

  # ── input validation ──

  def test_rejects_unknown_mode
    assert_raises(ArgumentError) do
      YoutubeBatch.new(podcasts: %w[a], mode: :weird, cursor_path: @cursor, pending_lookup: ->(_) { 0 })
    end
  end

  def test_rejects_empty_podcasts
    assert_raises(ArgumentError) do
      YoutubeBatch.new(podcasts: [], mode: :priority, cursor_path: @cursor, pending_lookup: ->(_) { 0 })
    end
  end
end
