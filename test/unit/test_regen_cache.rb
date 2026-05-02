# frozen_string_literal: true

require_relative "../test_helper"
require "regen_cache"

class TestRegenCache < Minitest::Test
  def setup
    RegenCache.reset!
  end

  def teardown
    RegenCache.reset!
  end

  def test_runs_block_first_time
    config = stub_config("pod_a")
    ran = 0
    RegenCache.ensure_regen(config) { ran += 1 }
    assert_equal 1, ran
  end

  def test_no_op_on_second_call_for_same_pod
    config = stub_config("pod_a")
    ran = 0
    RegenCache.ensure_regen(config) { ran += 1 }
    RegenCache.ensure_regen(config) { ran += 1 }
    assert_equal 1, ran
  end

  def test_runs_again_for_different_pod
    cfg_a = stub_config("pod_a")
    cfg_b = stub_config("pod_b")
    seen = []
    RegenCache.ensure_regen(cfg_a) { seen << "a" }
    RegenCache.ensure_regen(cfg_b) { seen << "b" }
    RegenCache.ensure_regen(cfg_a) { seen << "a2" }
    assert_equal %w[a b], seen
  end

  def test_reset_re_arms
    config = stub_config("pod_a")
    ran = 0
    RegenCache.ensure_regen(config) { ran += 1 }
    RegenCache.reset!
    RegenCache.ensure_regen(config) { ran += 1 }
    assert_equal 2, ran
  end

  def test_returns_block_value_on_first_call
    config = stub_config("pod_a")
    result = RegenCache.ensure_regen(config) { :ran }
    assert_equal :ran, result
  end

  def test_returns_nil_on_subsequent_calls
    config = stub_config("pod_a")
    RegenCache.ensure_regen(config) { :first }
    result = RegenCache.ensure_regen(config) { :second }
    assert_nil result
  end

  def test_keyed_by_config_name
    cfg_a1 = stub_config("pod_a")
    cfg_a2 = stub_config("pod_a")
    seen = []
    RegenCache.ensure_regen(cfg_a1) { seen << "a1" }
    RegenCache.ensure_regen(cfg_a2) { seen << "a2" }
    assert_equal ["a1"], seen, "different config instances with same name should share cache"
  end

  private

  def stub_config(name)
    Struct.new(:name).new(name)
  end
end
