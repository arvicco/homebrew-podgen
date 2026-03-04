# frozen_string_literal: true

require_relative "../test_helper"

# Load just the class without running the full pipeline
root = File.expand_path("../..", __dir__)
require_relative File.join(root, "lib", "cli", "language_pipeline")

class TestLanguagePipelineHelpers < Minitest::Test
  # --- find_speech_end_timestamp ---

  def test_find_speech_end_exact_match
    groq_words = [
      { word: "Hello", start: 0.0, end: 0.5 },
      { word: "world", start: 0.6, end: 1.0 },
      { word: "this", start: 1.1, end: 1.5 },
      { word: "is", start: 1.6, end: 1.8 },
      { word: "great", start: 1.9, end: 2.5 }
    ]

    result = pipeline.send(:find_speech_end_timestamp, "Hello world this is great", groq_words)
    assert_in_delta 2.5, result
  end

  def test_find_speech_end_fuzzy_prefix_match
    # Reconciled text has "sanjam" but Groq has "sanja" (inflection difference)
    groq_words = [
      { word: "Lepo", start: 0.0, end: 0.5 },
      { word: "sanja", start: 0.6, end: 1.2 }
    ]

    result = pipeline.send(:find_speech_end_timestamp, "Lepo sanjam", groq_words)
    assert_in_delta 1.2, result
  end

  def test_find_speech_end_no_match
    groq_words = [
      { word: "completely", start: 0.0, end: 0.5 },
      { word: "different", start: 0.6, end: 1.0 }
    ]

    result = pipeline.send(:find_speech_end_timestamp, "Hello world", groq_words)
    assert_nil result
  end

  def test_find_speech_end_empty_text
    result = pipeline.send(:find_speech_end_timestamp, "", [])
    assert_nil result
  end

  def test_find_speech_end_single_word
    groq_words = [
      { word: "Hello", start: 0.0, end: 0.5 },
      { word: "world", start: 0.6, end: 1.0 }
    ]

    result = pipeline.send(:find_speech_end_timestamp, "world", groq_words)
    assert_in_delta 1.0, result
  end

  def test_find_speech_end_ignores_punctuation
    groq_words = [
      { word: "Hello,", start: 0.0, end: 0.5 },
      { word: "world!", start: 0.6, end: 1.0 }
    ]

    result = pipeline.send(:find_speech_end_timestamp, "Hello, world!", groq_words)
    assert_in_delta 1.0, result
  end

  def test_find_speech_end_case_insensitive
    groq_words = [
      { word: "HELLO", start: 0.0, end: 0.5 },
      { word: "WORLD", start: 0.6, end: 1.0 }
    ]

    result = pipeline.send(:find_speech_end_timestamp, "hello world", groq_words)
    assert_in_delta 1.0, result
  end

  # --- normalize_word ---

  def test_normalize_word_strips_punctuation
    assert_equal "hello", pipeline.send(:normalize_word, "Hello!")
    assert_equal "world", pipeline.send(:normalize_word, "world,")
    assert_equal "noč", pipeline.send(:normalize_word, "noč.")
  end

  def test_normalize_word_downcases
    assert_equal "hello", pipeline.send(:normalize_word, "HELLO")
  end

  # --- word_match? ---

  def test_word_match_exact
    assert pipeline.send(:word_match?, "hello", "hello")
  end

  def test_word_match_prefix
    assert pipeline.send(:word_match?, "san", "sanjam")
    assert pipeline.send(:word_match?, "sanja", "sanjam")
  end

  def test_word_match_short_prefix_rejected
    refute pipeline.send(:word_match?, "sa", "sanjam")
  end

  def test_word_match_no_match
    refute pipeline.send(:word_match?, "hello", "world")
  end

  # --- format_timestamp ---

  def test_format_timestamp
    assert_equal "0:00.0", pipeline.send(:format_timestamp, 0)
    assert_equal "1:30.0", pipeline.send(:format_timestamp, 90)
    assert_equal "2:05.5", pipeline.send(:format_timestamp, 125.5)
  end

  # --- build_local_episode ---

  def test_build_local_episode_with_title
    path = create_temp_file("test.mp3", "audio data")
    ep = pipeline.send(:build_local_episode, path, "My Title")

    assert_equal "My Title", ep[:title]
    assert_match(/^file:\/\//, ep[:audio_url])
    assert_equal "", ep[:description]
  end

  def test_build_local_episode_auto_title
    path = create_temp_file("my-cool_episode.mp3", "audio data")
    ep = pipeline.send(:build_local_episode, path, nil)

    assert_equal "My Cool Episode", ep[:title]
  end

  def test_build_local_episode_raises_for_missing_file
    assert_raises(RuntimeError) { pipeline.send(:build_local_episode, "/nonexistent.mp3", nil) }
  end

  def test_build_local_episode_raises_for_empty_file
    path = create_temp_file("empty.mp3", "")
    assert_raises(RuntimeError) { pipeline.send(:build_local_episode, path, nil) }
  end

  # --- already_processed? ---

  def test_already_processed_returns_false_with_force
    p = pipeline(options: { force: true })
    ep = { audio_url: "http://example.com/ep.mp3", title: "T" }
    refute p.send(:already_processed?, ep)
  end

  def test_already_processed_returns_false_for_new_url
    ep = { audio_url: "http://example.com/new.mp3", title: "T" }
    refute pipeline.send(:already_processed?, ep)
  end

  private

  def pipeline(options: {})
    opts = { force: false, dry_run: false }.merge(options)
    config = Struct.new(:history_path).new("/dev/null")
    history = Struct.new(:all_urls).new(Set.new)
    logger = Struct.new(:log_method).new(nil)
    logger.define_singleton_method(:log) { |_| }
    logger.define_singleton_method(:phase_start) { |_| }
    logger.define_singleton_method(:phase_end) { |_| }
    logger.define_singleton_method(:error) { |_| }

    PodgenCLI::LanguagePipeline.allocate.tap do |p|
      p.instance_variable_set(:@config, config)
      p.instance_variable_set(:@options, opts)
      p.instance_variable_set(:@dry_run, opts[:dry_run])
      p.instance_variable_set(:@logger, logger)
      p.instance_variable_set(:@history, history)
      p.instance_variable_set(:@today, "2026-01-15")
      p.instance_variable_set(:@temp_files, [])
    end
  end

  def create_temp_file(name, content)
    @tmpdir ||= Dir.mktmpdir("lp_test")
    path = File.join(@tmpdir, name)
    File.write(path, content)
    path
  end

  def teardown
    FileUtils.rm_rf(@tmpdir) if @tmpdir
  end
end
