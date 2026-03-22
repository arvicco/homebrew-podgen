# frozen_string_literal: true

require_relative "../test_helper"
require "tell/engine_pool"
require "tell/engine"

class TestTellEnginePool < Minitest::Test
  def setup
    @original_key = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "test-key"
  end

  def teardown
    ENV["ANTHROPIC_API_KEY"] = @original_key
  end

  # --- Glosser caching ---

  def test_glosser_returns_same_instance_for_same_model
    pool = Tell::EnginePool.new
    g1 = pool.glosser("claude-opus-4-6")
    g2 = pool.glosser("claude-opus-4-6")

    assert_same g1, g2
  end

  def test_glosser_returns_different_instances_for_different_models
    pool = Tell::EnginePool.new
    g1 = pool.glosser("claude-opus-4-6")
    g2 = pool.glosser("claude-sonnet-4-6")

    refute_same g1, g2
  end

  def test_glosser_raises_without_api_key
    ENV.delete("ANTHROPIC_API_KEY")
    pool = Tell::EnginePool.new

    assert_raises(RuntimeError) { pool.glosser("claude-opus-4-6") }
  end

  def test_glosser_is_thread_safe
    pool = Tell::EnginePool.new
    results = Array.new(10)

    threads = 10.times.map do |i|
      Thread.new { results[i] = pool.glosser("claude-opus-4-6") }
    end
    threads.each(&:join)

    assert results.all? { |g| g.equal?(results[0]) },
           "Expected all threads to receive the same Glosser instance"
  end

  # --- Translator caching ---

  def test_translator_returns_same_instance_for_same_config
    pool = Tell::EnginePool.new
    args = { engines: ["deepl"], api_keys: { "deepl" => "key" }, timeout: 8.0 }

    t1 = pool.translator(**args)
    t2 = pool.translator(**args)

    assert_same t1, t2
  end

  def test_translator_returns_different_instances_for_different_config
    pool = Tell::EnginePool.new
    t1 = pool.translator(engines: ["deepl"], api_keys: { "deepl" => "key" }, timeout: 8.0)
    t2 = pool.translator(engines: ["claude"], api_keys: { "claude" => "key" }, timeout: 8.0)

    refute_same t1, t2
  end

  def test_translator_is_thread_safe
    pool = Tell::EnginePool.new
    args = { engines: ["deepl"], api_keys: { "deepl" => "key" }, timeout: 8.0 }
    results = Array.new(10)

    threads = 10.times.map do |i|
      Thread.new { results[i] = pool.translator(**args) }
    end
    threads.each(&:join)

    assert results.all? { |t| t.equal?(results[0]) },
           "Expected all threads to receive the same TranslatorChain instance"
  end

  # --- Engine integration ---

  def test_engine_delegates_to_pool_for_glosser
    pool = Tell::EnginePool.new
    config = Struct.new(:target_language, :gloss_model, :phonetic_model,
                        :gloss_reconciler, :phonetic_reconciler,
                        keyword_init: true)
      .new(target_language: "sl", gloss_model: ["claude-opus-4-6"],
           phonetic_model: ["claude-opus-4-6"],
           gloss_reconciler: "claude-opus-4-6",
           phonetic_reconciler: "claude-opus-4-6")

    engine = Tell::Engine.new(config, glosser_pool: pool)

    # Trigger glosser creation through Engine
    glosser_via_engine = engine.send(:build_glosser, "claude-opus-4-6")
    glosser_via_pool = pool.glosser("claude-opus-4-6")

    assert_same glosser_via_engine, glosser_via_pool
  end

  def test_engine_falls_back_to_local_without_pool
    config = Struct.new(:target_language, keyword_init: true)
      .new(target_language: "sl")

    engine = Tell::Engine.new(config)
    glosser = engine.send(:build_glosser, "claude-opus-4-6")

    assert_instance_of Tell::Glosser, glosser
  end
end
