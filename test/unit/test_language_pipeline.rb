# frozen_string_literal: true

require_relative "../test_helper"
require "yaml"
require "date"
require "fileutils"
require "episode_history"
require "agents/description_agent"
require "cli/language_pipeline"
require "time_value"
require "json"
require "subtitle_reconciler"

# Minimal logger that captures messages without file I/O
class StubLogger
  attr_reader :messages, :errors

  def initialize
    @messages = []
    @errors = []
  end

  def log(msg) = @messages << msg
  def error(msg) = @errors << msg
  def phase_start(_name) = nil
  def phase_end(_name) = nil
end

# Minimal config double exposing only the fields private methods need
StubConfig = Struct.new(
  :podcast_dir, :episodes_dir, :history_path, :excluded_urls_path, :author,
  :cover_base_image, :cover_options, :cover_generation_enabled,
  :lingq_config, :lingq_enabled, :transcription_language,
  :transcription_engines, :target_language,
  :skip, :cut, :autotrim, :name,
  keyword_init: true
) do
  def cover_generation_enabled? = cover_generation_enabled
  def lingq_enabled? = lingq_enabled
  def episode_basename(_date) = "test-2026-03-10"
  def auto_cover_config = {}
  def min_length_seconds; nil; end
  def max_length_seconds; nil; end
end

# Stub DescriptionAgent for testing clean_or_generate_description
class StubDescriptionAgent
  def initialize(clean_title: nil, clean: nil, generate: nil, generate_title: nil)
    @clean_title_result = clean_title
    @clean_result = clean
    @generate_result = generate
    @generate_title_result = generate_title
  end

  def clean_title(title:) = @clean_title_result || title
  def clean(title:, description:) = @clean_result || description
  def generate(title:, transcript:) = @generate_result || ""
  def generate_title(transcript:, language:) = @generate_title_result
end

class TestLanguagePipeline < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_lp_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)

    @logger = StubLogger.new
    @history = EpisodeHistory.new(File.join(@tmpdir, "history.yml"))

    @config = StubConfig.new(
      podcast_dir: @tmpdir,
      episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      excluded_urls_path: File.join(@tmpdir, "excluded_urls.yml"),
      author: "Test Author",
      cover_base_image: nil,
      cover_options: {},
      cover_generation_enabled: false,
      lingq_config: nil,
      lingq_enabled: false,
      transcription_language: "sl"
    )
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- write_transcript_file ---

  def test_write_transcript_file_creates_markdown
    pipeline = build_pipeline
    episode = { title: "My Episode", description: "Episode desc" }
    path = File.join(@episodes_dir, "test_transcript.md")

    pipeline.send(:write_transcript_file, path, episode, "Hello world transcript.")

    content = File.read(path)
    assert_includes content, "# My Episode"
    assert_includes content, "Episode desc"
    assert_includes content, "## Transcript"
    assert_includes content, "Hello world transcript."
  end

  def test_write_transcript_file_omits_empty_description
    pipeline = build_pipeline
    episode = { title: "No Desc", description: "" }
    path = File.join(@episodes_dir, "test_transcript.md")

    pipeline.send(:write_transcript_file, path, episode, "Text.")

    content = File.read(path)
    assert_includes content, "# No Desc"
    assert_includes content, "## Transcript"
    refute_includes content, "Episode desc"
  end

  def test_write_transcript_file_creates_directory
    pipeline = build_pipeline
    episode = { title: "Test", description: nil }
    nested_path = File.join(@episodes_dir, "sub", "transcript.md")

    pipeline.send(:write_transcript_file, nested_path, episode, "Content")

    assert File.exist?(nested_path)
  end

  # record_lingq_upload tests moved to test_post_pipeline_uploads.rb with
  # the extraction of upload side effects out of the pipeline.

  # --- resolve_episode_cover (delegation wiring) ---
  # The chain itself is tested in test_episode_cover_resolver.rb; these
  # verify the pipeline passes its state through and merges results back.

  def test_resolve_cover_delegates_pipeline_state_to_resolver
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_cover.jpg")

    path, desc = pipeline.send(:resolve_episode_cover, "Title")

    assert_equal "/tmp/rss_cover.jpg", path
    assert_includes desc, "RSS"
  end

  def test_resolve_cover_merges_resolver_warnings_into_pipeline
    pipeline = build_pipeline(options: { base_image: "/tmp/base.png" })

    CoverResolver.stub(:generate, ->(**_) { raise "magick exploded" }) do
      pipeline.send(:resolve_episode_cover, "Title")
    end

    warnings = pipeline.instance_variable_get(:@warnings)
    assert(warnings.any? { |w| w.include?("Cover generation failed") },
      "resolver warnings must merge into pipeline warnings, got: #{warnings.inspect}")
  end

  # --- skippable-step warnings must name the exception class ---

  def test_annotate_vocabulary_failure_warning_names_exception_class
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@staging_dir, @tmpdir)
    pipeline.instance_variable_set(:@base_name, "ep")

    TranscriptParser.stub(:parse_file, ->(_) { raise "boom" }) do
      pipeline.send(:annotate_vocabulary)
    end

    warn_line = @logger.messages.find { |m| m.include?("Vocabulary annotation failed") }
    refute_nil warn_line, "failure must be logged"
    assert_includes warn_line, "RuntimeError",
      "warning must name the exception class so permanent failures are distinguishable from transient ones"
  end

  # P9-8a: the pipeline passes the show's ledger (all published episodes; the
  # staged transcript is not in episodes_dir yet), the cache and the basename.
  def test_annotate_vocabulary_passes_ledger_cache_and_episode
    require "known_vocabulary"
    File.write(File.join(@episodes_dir, "test-2026-03-09_transcript.md"),
      "# T\n\n## Transcript\n\nTesto.\n\n## Vocabulary\n\n- **asino** (A1 noun) — donkey. An animal.\n")
    File.write(File.join(@tmpdir, "test-2026-03-10_transcript.md"), "# T\n\n## Transcript\n\nIl gatto.\n")
    cfg = @config.dup
    {vocabulary_level: "B1", vocabulary_max: 40, vocabulary_filters: {},
     vocabulary_target_languages: ["English"], transcription_language: "it"}.each do |k, v|
      cfg.define_singleton_method(k) { v }
    end
    pipeline = build_pipeline(config: cfg)
    pipeline.instance_variable_set(:@staging_dir, @tmpdir)
    pipeline.instance_variable_set(:@base_name, "test-2026-03-10")

    captured = nil
    annotator = Object.new
    annotator.define_singleton_method(:annotate) do |text, **kw|
      captured = kw
      [text, ""]
    end
    known = Object.new
    known.define_singleton_method(:lemma_set) { |_| Set.new }
    original_key = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_API_KEY"] = "test-key"
    VocabularyAnnotator.stub(:new, annotator) do
      KnownVocabulary.stub(:for_config, known) { pipeline.send(:annotate_vocabulary) }
    end

    refute_nil captured, "annotate was not called: #{@logger.messages.inspect}"
    assert_equal 1, captured[:ledger].episodes
    assert_equal ["test-2026-03-09"], captured[:ledger].explained("asino")
    assert_equal File.join(File.dirname(@episodes_dir), "vocab_cache.yml"), captured[:cache].path
    assert_equal "test-2026-03-10", captured[:episode]
  ensure
    ENV["ANTHROPIC_API_KEY"] = original_key
  end

  # --- reconcile_subtitles (runs through SubtitleReconciliationRunner, P4-2) ---

  def test_reconcile_subtitles_already_reconciled_skips_reconciler_and_logs
    pipeline = build_reconcile_pipeline("Text.", reconciled: true)

    calls = with_counting_reconciler { pipeline.send(:reconcile_subtitles) }

    assert_equal 0, calls
    assert @logger.messages.any? { |m| m.include?("skipped") && m.include?("already reconciled") },
      "expected an already-reconciled log line, got #{@logger.messages.inspect}"
    assert_empty pipeline.instance_variable_get(:@warnings)
  end

  def test_reconcile_subtitles_blank_text_skips_reconciler_and_logs
    pipeline = build_reconcile_pipeline("   ")

    calls = with_counting_reconciler { pipeline.send(:reconcile_subtitles) }

    assert_equal 0, calls
    assert @logger.messages.any? { |m| m.include?("skipped") && m.include?("empty") },
      "expected a blank-transcript log line, got #{@logger.messages.inspect}"
  end

  def test_reconcile_subtitles_missing_api_key_logs_reason
    pipeline = build_reconcile_pipeline("Text.")

    calls = with_counting_reconciler(api_key: nil) { pipeline.send(:reconcile_subtitles) }

    assert_equal 0, calls
    assert @logger.messages.any? { |m| m.include?("skipped") && m.include?("ANTHROPIC_API_KEY not set") },
      "expected a missing-key log line, got #{@logger.messages.inspect}"
  end

  # --- enforce_length_post_download ---

  def test_enforce_length_returns_nil_when_in_range
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :ok }
    pipeline.instance_variable_set(:@episode_source, fake_source)
    AudioAssembler.stub :probe_duration, 300.0 do
      result = pipeline.send(:enforce_length_post_download)
      assert_nil result
    end
  end

  def test_enforce_length_aborts_on_too_long_without_ask_trim
    pipeline = build_pipeline(options: {})
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    pipeline.instance_variable_set(:@config, build_config_with_length(min: 120, max: 570))
    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :too_long }
    pipeline.instance_variable_set(:@episode_source, fake_source)
    AudioAssembler.stub :probe_duration, 700.0 do
      result = pipeline.send(:enforce_length_post_download)
      assert_equal 1, result
    end
  end

  def test_enforce_length_with_ask_trim_excludes_on_x
    # `x` is the project-wide exclude key (matches other prompts in this file
    # at lines ~321,326 — "x to exclude" — and scrap_command).
    pipeline = build_pipeline(options: { ask_trim: true })
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    pipeline.instance_variable_set(:@config, build_config_with_length(min: 120, max: 570))
    pipeline.instance_variable_set(:@episode, { audio_url: "https://ex.com/ep.mp3" })

    excluded_url = nil
    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :too_long }
    fake_source.define_singleton_method(:exclude_url!) { |url| excluded_url = url }
    pipeline.instance_variable_set(:@episode_source, fake_source)

    out = nil
    $stdin.stub :gets, "x\n" do
      AudioAssembler.stub :probe_duration, 700.0 do
        out, _ = capture_io do
          result = pipeline.send(:enforce_length_post_download)
          assert_equal 0, result, "exclusion is a normal outcome (R1-e): exit 0"
        end
      end
    end
    assert_equal "https://ex.com/ep.mp3", excluded_url
    assert_match(/\[x\](?:clude|.*exclude)/i, out,
      "prompt must offer [x] for exclude (project-wide convention)")
  end

  def test_enforce_length_with_ask_trim_e_no_longer_triggers_exclude
    # Regression: "e" used to be the exclude key. After the rename to "x",
    # "e" must NOT call exclude_url! — it should fall through to abort.
    pipeline = build_pipeline(options: { ask_trim: true })
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    pipeline.instance_variable_set(:@config, build_config_with_length(min: 120, max: 570))
    pipeline.instance_variable_set(:@episode, { audio_url: "https://ex.com/ep.mp3" })

    exclude_called = false
    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :too_long }
    fake_source.define_singleton_method(:exclude_url!) { |_url| exclude_called = true }
    pipeline.instance_variable_set(:@episode_source, fake_source)

    $stdin.stub :gets, "e\n" do
      AudioAssembler.stub :probe_duration, 700.0 do
        capture_io { pipeline.send(:enforce_length_post_download) }
      end
    end
    refute exclude_called, "'e' must no longer trigger exclude_url!"
  end

  # --- re-post guard prompt (Q-88, P10-0) ---

  def test_acquire_rss_with_ask_trim_passes_duplicate_prompt_reading_stdin
    pipeline = build_pipeline(options: { ask_trim: true })
    passed = capture_fetch_next_kwargs(pipeline)
    prompt = passed[:duplicate_prompt]
    refute_nil prompt, "--ask-trim must pass a duplicate prompt"

    answer = nil
    err = nil
    $stdin.stub :gets, "k\n" do
      _, err = capture_io do
        answer = prompt.call({ title: "Il lupo e il pastore. Esopo" },
                             { basename: "fiabe-2026-04-28", date: "2026-04-28", title: "Il lupo e il pastore", same_feed: false })
      end
    end
    assert_equal "k", answer
    assert_includes err, '[d]uplicate skip / [k]eep (other feed — possibly a different telling; earlier: fiabe-2026-04-28 "Il lupo e il pastore")'
  end

  def test_duplicate_prompt_names_a_same_feed_match_as_a_likely_repost
    pipeline = build_pipeline(options: { ask_trim: true })
    prompt = capture_fetch_next_kwargs(pipeline)[:duplicate_prompt]

    err = nil
    $stdin.stub :gets, nil do
      _, err = capture_io do
        prompt.call({ title: "Il lupo e il pastore" },
                    { basename: "fiabe-2026-04-28", date: "2026-04-28", title: "Il lupo e il pastore", same_feed: true })
      end
    end
    assert_includes err, '[d]uplicate skip / [k]eep (same feed — likely a re-post; earlier: fiabe-2026-04-28 "Il lupo e il pastore")'
  end

  def test_acquire_rss_without_ask_trim_passes_no_duplicate_prompt
    pipeline = build_pipeline
    passed = capture_fetch_next_kwargs(pipeline)
    assert passed.key?(:duplicate_prompt)
    assert_nil passed[:duplicate_prompt]
  end

  def test_enforce_length_with_ask_trim_continues_on_t
    pipeline = build_pipeline(options: { ask_trim: true })
    pipeline.instance_variable_set(:@source_audio_path, "/tmp/x.mp3")
    pipeline.instance_variable_set(:@config, build_config_with_length(min: 120, max: 570))
    pipeline.instance_variable_set(:@episode, { audio_url: "https://ex.com/ep.mp3" })

    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| :too_long }
    pipeline.instance_variable_set(:@episode_source, fake_source)

    $stdin.stub :gets, "t\n" do
      AudioAssembler.stub :probe_duration, 700.0 do
        capture_io do
          result = pipeline.send(:enforce_length_post_download)
          assert_nil result
        end
      end
    end
  end

  def test_resolve_cover_per_feed_image_auto_uses_resolver_winner
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@current_episode_feed_image, "auto")
    pipeline.instance_variable_set(:@base_name, "show-2026-04-25")
    pipeline.instance_variable_set(:@episode, { description: "Episode about a king." })

    fake = Object.new
    fake.define_singleton_method(:try) do |title:, description:, episodes_dir:, basename:|
      { winner_path: "/tmp/winner.jpg", top_paths: ["/tmp/winner.jpg"], candidates: [{ score: 18 }] }
    end

    PodgenCLI::LanguagePipeline.const_get(:AutoCoverResolver).stub(:new, fake) do
      path, desc = pipeline.send(:resolve_episode_cover, "King Title")
      assert_equal "/tmp/winner.jpg", path
      assert_includes desc, "auto"
    end
  end

  def test_resolve_cover_per_feed_image_auto_persists_into_staging_dir
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@current_episode_feed_image, "auto")
    pipeline.instance_variable_set(:@base_name, "show-2026-04-25")
    pipeline.instance_variable_set(:@episode, { description: "x" })
    staging = pipeline.instance_variable_get(:@staging_dir)

    captured_dir = nil
    fake = Object.new
    fake.define_singleton_method(:try) do |title:, description:, episodes_dir:, basename:|
      captured_dir = episodes_dir
      { winner_path: nil, top_paths: [], candidates: [] }
    end

    PodgenCLI::LanguagePipeline.const_get(:AutoCoverResolver).stub(:new, fake) do
      pipeline.send(:resolve_episode_cover, "Title")
    end
    assert_equal staging, captured_dir,
                 "candidates must be persisted into @staging_dir so they participate in commit_episode's atomic move"
  end

  def test_resolve_cover_per_feed_image_auto_falls_through_when_no_winner
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@current_episode_feed_image, "auto")
    pipeline.instance_variable_set(:@base_name, "show-2026-04-25")
    pipeline.instance_variable_set(:@episode, { description: "x" })
    # Set RSS image so the chain has something to fall through TO
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_fallback.jpg")

    fake = Object.new
    fake.define_singleton_method(:try) { |**_kw| { winner_path: nil, top_paths: [], candidates: [] } }

    PodgenCLI::LanguagePipeline.const_get(:AutoCoverResolver).stub(:new, fake) do
      path, desc = pipeline.send(:resolve_episode_cover, "Title")
      assert_equal "/tmp/rss_fallback.jpg", path, "should fall through to RSS image when auto returns no winner"
      assert_includes desc, "RSS"
    end
  end

  def test_resolve_cover_base_image_option_beats_rss_image
    base_path = File.join(@tmpdir, "base.png")
    FileUtils.touch(base_path)

    config = build_config(cover_base_image: base_path, cover_generation_enabled: true)
    pipeline = build_pipeline(options: { base_image: base_path }, config: config)
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_cover.jpg")

    path, = pipeline.send(:resolve_episode_cover, "Title")
    refute_equal "/tmp/rss_cover.jpg", path
  end

  def test_resolve_cover_image_option_beats_rss_image
    image_path = File.join(@tmpdir, "explicit.png")
    FileUtils.touch(image_path)

    pipeline = build_pipeline(options: { image: image_path })
    pipeline.instance_variable_set(:@rss_episode_image, "/tmp/rss_cover.jpg")

    path, = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal File.expand_path(image_path), path
  end

  def test_resolve_cover_falls_through_to_youtube_thumbnail
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@youtube_thumbnail, "/tmp/yt.jpg")

    path, desc = pipeline.send(:resolve_episode_cover, "Title")
    assert_equal "/tmp/yt.jpg", path
    assert_includes desc, "thumbnail"
  end

  # --- cleanup_temp_files ---

  def test_cleanup_temp_files_removes_files
    f1 = File.join(@tmpdir, "temp1.mp3")
    f2 = File.join(@tmpdir, "temp2.mp3")
    FileUtils.touch(f1)
    FileUtils.touch(f2)

    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, [f1, f2])
    pipeline.instance_variable_set(:@trimmer, nil)

    pipeline.send(:cleanup_temp_files)

    refute File.exist?(f1)
    refute File.exist?(f2)
  end

  def test_cleanup_temp_files_ignores_missing
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, ["/nonexistent/file.mp3"])
    pipeline.instance_variable_set(:@trimmer, nil)

    # Should not raise
    pipeline.send(:cleanup_temp_files)
  end

  def test_cleanup_includes_trimmer_temp_files
    f1 = File.join(@tmpdir, "pipeline.mp3")
    f2 = File.join(@tmpdir, "trimmer.mp3")
    FileUtils.touch(f1)
    FileUtils.touch(f2)

    pipeline = build_pipeline
    pipeline.instance_variable_set(:@temp_files, [f1])

    trimmer_stub = Struct.new(:temp_files).new([f2])
    pipeline.instance_variable_set(:@trimmer, trimmer_stub)

    pipeline.send(:cleanup_temp_files)

    refute File.exist?(f1)
    refute File.exist?(f2)
  end

  # --- clean_or_generate_description ---

  def test_clean_or_generate_description_cleans_existing
    pipeline = build_pipeline
    episode = { title: "Test", description: "Original desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Test", clean: "Cleaned desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript text")
    end

    assert_equal "Cleaned desc", episode[:description]
  end

  def test_clean_or_generate_description_generates_when_empty
    pipeline = build_pipeline
    episode = { title: "Test", description: "" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Test", generate: "Generated desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript text")
    end

    assert_equal "Generated desc", episode[:description]
  end

  def test_clean_or_generate_description_cleans_title
    pipeline = build_pipeline
    episode = { title: "CATEGORY: Real Title", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Real Title", clean: "Desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    assert_equal "Real Title", episode[:title]
  end

  def test_clean_or_generate_description_non_fatal
    pipeline = build_pipeline
    episode = { title: "Test", description: "Keep me" }

    # Raise during agent construction
    DescriptionAgent.stub(:new, ->(**_) { raise "API error" }) do
      # Should not raise
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    # Original description preserved on error
    assert_equal "Keep me", episode[:description]
  end

  def test_generic_title_matching_podcast_name_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Basnie", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Basnie", clean: "Desc", generate_title: "Szczepan i smok")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "Dawno temu żył Szczepan...")
    end

    assert_equal "Szczepan i smok", episode[:title]
  end

  def test_non_generic_title_not_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Szczepan i smok", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(clean_title: "Szczepan i smok", clean: "Desc")
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript")
    end

    assert_equal "Szczepan i smok", episode[:title]
  end

  def test_wrong_language_description_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Story Title", description: "Audiobook fairy tales with stories and morals for children and families" }

    stub_agent = StubDescriptionAgent.new(
      clean_title: "Story Title",
      clean: "Audiobook fairy tales with stories and morals for children and families",
      generate: "Opowieść o chłopcu i smoku."
    )
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "Dawno temu żył sobie chłopiec")
    end

    assert_equal "Opowieść o chłopcu i smoku.", episode[:description]
  end

  def test_correct_language_description_not_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Title", description: "Opowieść o chłopcu który spotkał smoka w lesie" }

    stub_agent = StubDescriptionAgent.new(
      clean_title: "Title",
      clean: "Opowieść o chłopcu który spotkał smoka w lesie"
    )
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "transcript")
    end

    assert_equal "Opowieść o chłopcu który spotkał smoka w lesie", episode[:description]
  end

  def test_wrong_language_title_regenerated
    pipeline = build_pipeline(name: "Basnie", transcription_language: "pl")
    episode = { title: "Audio fairy tales for children and families to enjoy", description: "Desc" }

    stub_agent = StubDescriptionAgent.new(
      clean_title: "Audio fairy tales for children and families to enjoy",
      clean: "Desc",
      generate_title: "Szczepan i smok"
    )
    DescriptionAgent.stub(:new, stub_agent) do
      pipeline.send(:clean_or_generate_description, episode, "Dawno temu żył Szczepan...")
    end

    assert_equal "Szczepan i smok", episode[:title]
  end

  # --- warnings tracking ---

  def test_description_failure_adds_warning
    pipeline = build_pipeline
    episode = { title: "Test", description: "Keep me" }

    DescriptionAgent.stub(:new, ->(**_) { raise "API error" }) do
      pipeline.send(:clean_or_generate_description, episode, "text")
    end

    warnings = pipeline.instance_variable_get(:@warnings)
    assert_equal 1, warnings.size
    assert_includes warnings.first, "Description cleanup failed (RuntimeError: API error)"
  end

  def test_reconciliation_failure_raises_error
    config = StubConfig.new(
      podcast_dir: @tmpdir, episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      author: "Test", cover_base_image: nil, cover_options: {},
      cover_generation_enabled: false, lingq_config: nil, lingq_enabled: false,
      transcription_language: "sl",
      transcription_engines: %w[open groq], target_language: "en"
    )
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@config, config)

    fake_manager = Object.new
    fake_manager.define_singleton_method(:transcribe) do |*, **|
      { all: { "open" => { text: "raw" }, "groq" => { text: "raw" } },
        errors: {}, reconciled: nil, primary: { text: "raw" } }
    end

    err = assert_raises(RuntimeError) do
      Transcription::EngineManager.stub(:new, fake_manager) do
        pipeline.send(:transcribe_audio, "/fake/audio.mp3")
      end
    end
    assert_includes err.message, "reconciliation failed"
  end

  def test_log_completion_with_warnings_shows_warning_marker
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")
    pipeline.instance_variable_get(:@warnings) << "Test warning"

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("\u26A0") }
    assert @logger.messages.any? { |m| m.include?("with warnings") }
    assert @logger.messages.any? { |m| m.include?("Test warning") }
  end

  def test_log_completion_without_warnings_shows_checkmark
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("\u2713") }
    refute @logger.messages.any? { |m| m.include?("warning") }
  end

  def test_log_completion_lists_multiple_warnings
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.instance_variable_set(:@output_path, "/tmp/test.mp3")
    warnings = pipeline.instance_variable_get(:@warnings)
    warnings << "Warning one"
    warnings << "Warning two"

    pipeline.send(:log_completion)

    assert @logger.messages.any? { |m| m.include?("Warning one") }
    assert @logger.messages.any? { |m| m.include?("Warning two") }
  end

  # --- log_dry_run ---

  def test_log_dry_run_logs_summary
    pipeline = build_pipeline(options: { verbosity: :quiet })
    pipeline.instance_variable_set(:@pipeline_start, Time.now - 1)
    pipeline.send(:log_dry_run, "Config validated")

    assert @logger.messages.any? { |m| m.include?("dry-run") }
    assert @logger.messages.any? { |m| m.include?("Config validated") }
  end

  # --- validate_image_options ---

  def test_validate_image_options_thumb_without_url_returns_error
    pipeline = build_pipeline(options: { image: "thumb" })
    # No @youtube_url set
    result = pipeline.send(:validate_image_options)
    assert_equal 1, result
  end

  def test_validate_image_options_thumb_with_url_returns_nil
    pipeline = build_pipeline(options: { image: "thumb", url: "https://youtube.com/watch?v=abc" })
    pipeline.instance_variable_set(:@youtube_url, "https://youtube.com/watch?v=abc")
    result = pipeline.send(:validate_image_options)
    assert_nil result
  end

  def test_validate_image_options_nil_returns_nil
    pipeline = build_pipeline
    result = pipeline.send(:validate_image_options)
    assert_nil result
  end

  def test_validate_image_options_last_with_no_screenshots
    pipeline = build_pipeline(options: { image: "last" })
    # Stub Dir.glob to return empty
    Dir.stub(:glob, []) do
      result = pipeline.send(:validate_image_options)
      assert_equal 1, result
    end
  end

  # --- --no-skip / --no-cut / --no-autotrim ---

  def test_no_skip_overrides_config_skip
    config = build_config(skip: 38.0)
    pipeline = build_pipeline(options: { no_skip: true }, config: config)
    pipeline.instance_variable_set(:@episode, { skip: 10.0 })
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    called_with = {}
    stub_trimmer(called_with) do
      pipeline.send(:trim_source_audio)
    end
    assert_nil called_with[:skip]
  end

  def test_no_cut_overrides_config_cut
    config = build_config(cut: 10.0)
    pipeline = build_pipeline(options: { no_cut: true }, config: config)
    pipeline.instance_variable_set(:@episode, { cut: 5.0 })
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    called_with = {}
    stub_trimmer(called_with) do
      pipeline.send(:trim_source_audio)
    end
    assert_nil called_with[:cut]
  end

  def test_no_autotrim_overrides_config_autotrim
    config = build_config(autotrim: true)
    pipeline = build_pipeline(options: { no_autotrim: true }, config: config)
    pipeline.instance_variable_set(:@episode, { autotrim: true })
    pipeline.instance_variable_set(:@reconciled_text, "some text")
    pipeline.instance_variable_set(:@groq_words, [{ word: "text", end: 10.0 }])

    pipeline.send(:trim_outro)

    assert @logger.messages.any? { |m| m.include?("autotrim not enabled") }
  end

  def test_skip_applies_without_no_skip_flag
    config = build_config(skip: 38.0)
    pipeline = build_pipeline(config: config)
    pipeline.instance_variable_set(:@episode, {})
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    called_with = {}
    stub_trimmer(called_with) do
      pipeline.send(:trim_source_audio)
    end
    assert_equal 38.0, called_with[:skip]
  end

  # --- ask_trim exclude ---

  def test_ask_trim_x_at_skip_prompt_excludes_episode
    config = build_config
    pipeline = build_pipeline(options: { ask_trim: true }, config: config)
    episode = { title: "Unwanted Episode", audio_url: "https://example.com/ep1.mp3?utm_source=rss&fbclid=abc" }
    pipeline.instance_variable_set(:@episode, episode)
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    # Stub probe_duration and system("open", ...) to avoid real calls
    fake_assembler = Minitest::Mock.new
    fake_assembler.expect(:probe_duration, 120.0, ["/fake/audio.mp3"])

    $stdin.stub(:gets, "x\n") do
      AudioAssembler.stub(:new, fake_assembler) do
        pipeline.stub(:start_preview, nil) do
          result = pipeline.send(:trim_source_audio)
          assert_equal :excluded, result
        end
      end
    end

    excluded_path = config.excluded_urls_path
    assert File.exist?(excluded_path), "excluded_urls.yml should be created"
    excluded = YAML.load_file(excluded_path)
    assert_includes excluded, "https://example.com/ep1.mp3"
    refute excluded.any? { |u| u.include?("utm_source") }, "tracking params should be cleaned"
    assert @logger.messages.any? { |m| m.include?("Excluded episode") }
  end

  def test_ask_trim_x_at_cut_prompt_excludes_episode
    config = build_config
    pipeline = build_pipeline(options: { ask_trim: true }, config: config)
    episode = { title: "Unwanted Episode", audio_url: "https://example.com/ep2.mp3" }
    pipeline.instance_variable_set(:@episode, episode)
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    fake_assembler = Minitest::Mock.new
    fake_assembler.expect(:probe_duration, 120.0, ["/fake/audio.mp3"])

    # First gets returns "10" (skip value), second returns "x" (exclude at cut prompt)
    inputs = ["10\n", "x\n"]
    call_count = 0
    fake_gets = -> { r = inputs[call_count]; call_count += 1; r }

    AudioAssembler.stub(:new, fake_assembler) do
      pipeline.stub(:start_preview, nil) do
        $stdin.stub(:gets, fake_gets) do
          result = pipeline.send(:trim_source_audio)
          assert_equal :excluded, result
        end
      end
    end

    excluded = YAML.load_file(config.excluded_urls_path)
    assert_includes excluded, "https://example.com/ep2.mp3"
  end

  def test_ask_trim_normal_input_does_not_exclude
    config = build_config
    pipeline = build_pipeline(options: { ask_trim: true }, config: config)
    episode = { title: "Good Episode", audio_url: "https://example.com/ep3.mp3" }
    pipeline.instance_variable_set(:@episode, episode)
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    fake_assembler = Minitest::Mock.new
    fake_assembler.expect(:probe_duration, 120.0, ["/fake/audio.mp3"])

    inputs = ["5\n", "10\n"]
    call_count = 0
    fake_gets = -> { r = inputs[call_count]; call_count += 1; r }

    called_with = {}
    fake_trimmer = Object.new
    fake_trimmer.define_singleton_method(:apply_trim) do |path, skip:, cut:, snip:|
      called_with[:skip] = skip
      called_with[:cut] = cut
      path
    end

    AudioAssembler.stub(:new, fake_assembler) do
      AudioTrimmer.stub(:new, fake_trimmer) do
        pipeline.stub(:start_preview, nil) do
          $stdin.stub(:gets, fake_gets) do
            result = pipeline.send(:trim_source_audio)
            refute_equal :excluded, result
          end
        end
      end
    end

    refute File.exist?(config.excluded_urls_path)
    assert_equal 5.0, called_with[:skip]
    assert_equal 10.0, called_with[:cut]
  end

  # --- ask_trim preview via QuickTime Player (P00-7) ---
  # QT: frontmost + autoplay natively scriptable (Quick Look could do
  # neither from a spawned process); still imports nothing.

  def test_preview_open_command_uses_quicktime
    pipeline = build_pipeline
    assert_equal ["open", "-a", "QuickTime Player", "/fake/audio.mp3"],
      pipeline.send(:preview_open_command, "/fake/audio.mp3")
  end

  def run_ask_trim(pipeline, input:)
    calls = {system: [], spawned: []}
    pipeline.define_singleton_method(:system) { |*args| calls[:system] << args; true }
    pipeline.define_singleton_method(:spawn) { |*args| calls[:spawned] << args; 4242 }

    fake_assembler = Minitest::Mock.new
    fake_assembler.expect(:probe_duration, 120.0, ["/fake/audio.mp3"])

    result = nil
    AudioAssembler.stub(:new, fake_assembler) do
      Process.stub(:detach, nil) do
        $stdin.stub(:gets, input) do
          result = pipeline.send(:ask_trim_interactive)
        end
      end
    end
    [result, calls]
  end

  def test_ask_trim_opens_quicktime_frontmost_and_autoplays
    pipeline = build_pipeline(options: {ask_trim: true})
    pipeline.instance_variable_set(:@episode, {title: "Ep"})
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    _result, calls = run_ask_trim(pipeline, input: "\n")

    assert_equal pipeline.send(:preview_open_command, "/fake/audio.mp3"),
      calls[:system].first, "must open via open -a (frontmost, no launch race)"
    play = calls[:spawned].first
    refute_nil play, "autoplay osascript must be spawned in background"
    assert_equal "osascript", play.first
    assert_includes play.join(" "), "play front document"
  end

  def test_ask_trim_closes_quicktime_document_after_prompts_and_on_exclude
    ["\n", "x\n"].each do |input|
      pipeline = build_pipeline(options: {ask_trim: true})
      pipeline.instance_variable_set(:@episode, {title: "Ep"})
      pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

      result, calls = run_ask_trim(pipeline, input: input)

      assert_equal(:exclude, result) if input.start_with?("x")
      close = calls[:system].last
      assert_equal "osascript", close.first, "close script must run after prompts (input=#{input.inspect})"
      assert_includes close.join(" "), "close front document saving no"
    end
  end

  # --- listening archive (P11-0, Q-104) ---

  LISTEN_URL = "https://cdn.ex.com/show/ep1.mp3"

  def archive_root = File.join(@tmpdir, "archive")

  def build_listening_pipeline(options: { ask_trim: true }, config: build_config)
    pipeline = build_pipeline(options: options, config: config)
    source = File.join(@tmpdir, "podgen_source_test.mp3")
    File.binwrite(source, "ID3\x00source-audio\xFF".b)
    pipeline.instance_variable_set(:@episode, { title: "Zlata ribica", audio_url: LISTEN_URL })
    pipeline.instance_variable_set(:@source_audio_path, source)
    [pipeline, source]
  end

  # Runs trim_source_audio with scripted stdin (a Proc entry is called,
  # e.g. to raise Interrupt) and a trimmer that records what it saw.
  def run_listening_trim(pipeline, inputs, duration: 300.0)
    queue = inputs.dup
    fake_gets = -> { v = queue.shift; v.respond_to?(:call) ? v.call : v }
    fake_assembler = Object.new
    fake_assembler.define_singleton_method(:probe_duration) { |_p| duration }
    seen = {}
    fake_trimmer = Object.new
    fake_trimmer.define_singleton_method(:apply_trim) do |path, skip:, cut:, snip:|
      seen[:pair_at_trim] = Dir.glob(File.join(File.dirname(path), "archive", "*")).map { File.basename(it) }.sort
      seen[:skip] = skip
      seen[:cut] = cut
      path
    end
    result = nil
    AudioAssembler.stub(:new, fake_assembler) do
      AudioTrimmer.stub(:new, fake_trimmer) do
        pipeline.stub(:start_preview, nil) do
          $stdin.stub(:gets, fake_gets) do
            capture_io { result = pipeline.send(:trim_source_audio) }
          end
        end
      end
    end
    [result, seen]
  end

  def test_ask_trim_kept_episode_archives_source_copy_and_sidecar_before_trimming
    pipeline, source = build_listening_pipeline

    _result, seen = run_listening_trim(pipeline, ["0:49\n", "4:07\n"])

    copy = File.join(archive_root, "test-2026-03-10.source.mp3")
    assert File.exist?(copy), "untrimmed source must be archived"
    assert_equal File.binread(source), File.binread(copy)
    assert_equal ["test-2026-03-10.source.mp3", "test-2026-03-10.trim.yml"], seen[:pair_at_trim],
      "the pair is complete before the trimmer runs"
    data = YAML.load_file(File.join(archive_root, "test-2026-03-10.trim.yml"))
    assert_equal LISTEN_URL, data["audio_url"]
    assert_equal "Zlata ribica", data["title"]
    assert_equal "cdn.ex.com/show", data["feed_key"]
    assert_equal 300.0, data["source_duration"]
    assert_equal 49.0, data["skip"]
    assert_equal 247.0, data["cut"]
    assert_nil data["snip"]
    assert_equal [[49.0, 247.0]], data["kept_segments"]
    assert_equal 198.0, data["final_duration"]
    refute_nil data["recorded_at"]
  end

  def test_ask_trim_blank_values_still_archive_the_pair
    pipeline, _source = build_listening_pipeline

    run_listening_trim(pipeline, ["\n", "\n"])

    data = YAML.load_file(File.join(archive_root, "test-2026-03-10.trim.yml"))
    assert_nil data["skip"]
    assert_nil data["cut"]
    assert_equal [[0.0, 300.0]], data["kept_segments"]
    assert_equal 300.0, data["final_duration"]
  end

  def test_ask_trim_x_archives_the_rejected_download_with_reason_listened
    [[["x\n"], "skip"], [["10\n", "x\n"], "cut"]].each do |inputs, prompt|
      FileUtils.rm_rf(archive_root)
      pipeline, source = build_listening_pipeline

      result, = run_listening_trim(pipeline, inputs)

      assert_equal :excluded, result
      file = File.join(archive_root, "rejected", "2026-03-10-zlata-ribica.mp3")
      assert File.exist?(file), "rejected download must be archived (#{prompt})"
      assert_equal File.binread(source), File.binread(file)
      rows = YAML.load_file(File.join(archive_root, "rejected.yml"))
      assert_equal 1, rows.length
      assert_equal({ "audio_url" => LISTEN_URL, "title" => "Zlata ribica", "feed_key" => "cdn.ex.com/show",
                     "duration" => 300.0, "reason" => "listened", "prompt" => prompt },
        rows.first.slice("audio_url", "title", "feed_key", "duration", "reason", "prompt"))
      refute File.exist?(File.join(archive_root, "test-2026-03-10.trim.yml")), "no kept pair for a rejection"
      assert_includes YAML.load_file(@config.excluded_urls_path), LISTEN_URL, "selection filter unchanged"
    end
  end

  def test_ask_trim_interrupt_archives_rejection_and_hands_the_signal_on
    pipeline, source = build_listening_pipeline
    handed_on = false
    marker = proc { handed_on = true }
    original = Signal.trap("INT", marker)
    begin
      assert_raises(Interrupt) { run_listening_trim(pipeline, [-> { raise Interrupt }]) }
      restored = Signal.trap("INT", original)
    ensure
      Signal.trap("INT", original)
    end

    assert_same marker, restored, "the previous INT handler is restored"
    assert handed_on, "the previous handler (bin/podgen's exit 130) gets the signal"
    rows = YAML.load_file(File.join(archive_root, "rejected.yml"))
    assert_equal ["interrupted"], rows.map { it["reason"] }
    assert_equal "skip", rows.first["prompt"]
    assert File.exist?(File.join(archive_root, rows.first["file"])), "the download is kept"
    assert File.exist?(source)
    refute File.exist?(@config.excluded_urls_path), "an interrupt is not an exclusion"
  end

  # --- trim prompt re-ask on a bad value (P11-5, Q-103) ---

  def test_ask_trim_bad_value_reasks_then_accepts
    pipeline, _source = build_listening_pipeline
    pipeline.instance_variable_set(:@source_audio_path, "/fake/audio.mp3")

    result, calls = run_ask_trim(pipeline, input: fake_gets_from(["e43\n", "30\n", "\n"]))

    assert_equal [30.0, nil], result
    assert_equal "osascript", calls[:system].last.first, "preview still closes after a re-ask"
  end

  def test_ask_trim_three_bad_values_take_the_rejected_path_with_bad_input
    [[["e43\n", "x1\n", "1:2:3\n"], "skip"], [["10\n", "a\n", "b\n", "c\n"], "cut"]].each do |inputs, prompt|
      FileUtils.rm_rf(archive_root)
      FileUtils.rm_f(@config.excluded_urls_path)
      pipeline, _source = build_listening_pipeline

      result, seen = run_listening_trim(pipeline, inputs)

      assert_equal :excluded, result
      assert_nil seen[:skip], "the trimmer never runs"
      rows = YAML.load_file(File.join(archive_root, "rejected.yml"))
      assert_equal [["bad_input", prompt]], rows.map { [it["reason"], it["prompt"]] }
      assert_includes YAML.load_file(@config.excluded_urls_path), LISTEN_URL
    end
  end

  def fake_gets_from(inputs)
    queue = inputs.dup
    -> { queue.shift }
  end

  def test_unattended_trim_writes_nothing_to_the_archive
    pipeline, _source = build_listening_pipeline(options: {}, config: build_config(skip: 10))

    run_listening_trim(pipeline, [])

    refute Dir.exist?(archive_root), "unattended runs never write the archive"
  end

  def run_length_prompt(answer, verdict:, duration:)
    pipeline, source = build_listening_pipeline
    pipeline.instance_variable_set(:@config, build_config_with_length(min: 120, max: 570))
    fake_source = Object.new
    fake_source.define_singleton_method(:length_check) { |_d| verdict }
    fake_source.define_singleton_method(:exclude_url!) { |_url| nil }
    pipeline.instance_variable_set(:@episode_source, fake_source)
    result = nil
    $stdin.stub :gets, answer do
      AudioAssembler.stub :probe_duration, duration do
        capture_io { result = pipeline.send(:enforce_length_post_download) }
      end
    end
    [result, source]
  end

  def test_length_prompt_x_archives_rejection_with_too_long_or_too_short
    [[:too_long, 700.0, "too_long"], [:too_short, 60.0, "too_short"]].each do |verdict, duration, reason|
      FileUtils.rm_rf(archive_root)
      result, source = run_length_prompt("x\n", verdict: verdict, duration: duration)

      assert_equal 0, result
      rows = YAML.load_file(File.join(archive_root, "rejected.yml"))
      assert_equal [[reason, "length", duration, "cdn.ex.com/show"]],
        rows.map { [it["reason"], it["prompt"], it["duration"], it["feed_key"]] }
      assert_equal File.binread(source), File.binread(File.join(archive_root, rows.first["file"]))
    end
  end

  def test_length_prompt_abort_archives_rejection_with_reason_aborted
    result, _source = run_length_prompt("a\n", verdict: :too_long, duration: 700.0)

    assert_equal 1, result
    rows = YAML.load_file(File.join(archive_root, "rejected.yml"))
    assert_equal [["aborted", "length"]], rows.map { [it["reason"], it["prompt"]] }
  end

  def test_length_prompt_trim_choice_archives_nothing_yet
    result, _source = run_length_prompt("t\n", verdict: :too_long, duration: 700.0)

    assert_nil result
    refute Dir.exist?(archive_root)
  end

  def test_listening_window_interrupt_in_length_prompt_is_archived_and_reraised
    pipeline, _source = build_listening_pipeline
    original = Signal.trap("INT", "DEFAULT")
    begin
      assert_raises(Interrupt) do
        pipeline.send(:listening_window, "length") { raise Interrupt }
      end
    ensure
      Signal.trap("INT", original)
    end
    rows = YAML.load_file(File.join(archive_root, "rejected.yml"))
    assert_equal [["interrupted", "length"]], rows.map { [it["reason"], it["prompt"]] }
  end

  def test_listening_window_without_ask_trim_leaves_the_trap_alone
    pipeline, _source = build_listening_pipeline(options: {})
    marker = proc {}
    original = Signal.trap("INT", marker)
    begin
      inside = pipeline.send(:listening_window, "length") { Signal.trap("INT", marker) }
      assert_same marker, inside, "no handler is installed for unattended runs"
    ensure
      Signal.trap("INT", original)
    end
    refute Dir.exist?(archive_root)
  end

  # --- staged output lifecycle ---

  def test_setup_staging_creates_directory
    pipeline = build_pipeline
    staging = pipeline.instance_variable_get(:@staging_dir)

    pipeline.send(:setup_staging)
    assert Dir.exist?(staging)
  ensure
    FileUtils.rm_rf(staging)
  end

  def test_setup_staging_clears_prior_contents
    pipeline = build_pipeline
    staging = pipeline.instance_variable_get(:@staging_dir)
    FileUtils.mkdir_p(staging)
    File.write(File.join(staging, "leftover.mp3"), "old")

    pipeline.send(:setup_staging)
    assert Dir.exist?(staging)
    assert_empty Dir.glob(File.join(staging, "*"))
  ensure
    FileUtils.rm_rf(staging)
  end

  def test_commit_episode_moves_files_to_episodes
    pipeline = build_pipeline
    staging = pipeline.instance_variable_get(:@staging_dir)
    FileUtils.mkdir_p(staging)
    pipeline.instance_variable_set(:@base_name, "test-2026-03-10")
    pipeline.instance_variable_set(:@episode, { title: "Test", audio_url: "http://test.mp3" })
    pipeline.instance_variable_set(:@today, Date.new(2026, 3, 10))
    pipeline.instance_variable_set(:@history, EpisodeHistory.new(File.join(@tmpdir, "history.yml")))

    # Create staged files
    File.write(File.join(staging, "test-2026-03-10.mp3"), "audio")
    File.write(File.join(staging, "test-2026-03-10_transcript.md"), "text")

    pipeline.send(:commit_episode)

    assert File.exist?(File.join(@episodes_dir, "test-2026-03-10.mp3"))
    assert File.exist?(File.join(@episodes_dir, "test-2026-03-10_transcript.md"))
    assert_equal File.join(@episodes_dir, "test-2026-03-10.mp3"), pipeline.instance_variable_get(:@output_path)
  ensure
    FileUtils.rm_rf(staging)
  end

  def test_cleanup_staging_removes_directory
    pipeline = build_pipeline
    staging = pipeline.instance_variable_get(:@staging_dir)
    FileUtils.mkdir_p(staging)
    File.write(File.join(staging, "orphan.mp3"), "data")

    pipeline.send(:cleanup_staging)
    refute Dir.exist?(staging)
  end

  private

  def build_config(**overrides)
    StubConfig.new(
      podcast_dir: @tmpdir,
      episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      excluded_urls_path: File.join(@tmpdir, "excluded_urls.yml"),
      author: "Test Author",
      cover_base_image: nil,
      cover_options: {},
      cover_generation_enabled: false,
      lingq_config: nil,
      lingq_enabled: false,
      transcription_language: "sl",
      **overrides
    )
  end

  def build_config_with_length(min:, max:)
    klass = Class.new(StubConfig) do
      attr_accessor :min_length_override, :max_length_override
      def min_length_seconds; @min_length_override; end
      def max_length_seconds; @max_length_override; end
    end
    cfg = klass.new(
      podcast_dir: @tmpdir,
      episodes_dir: @episodes_dir,
      history_path: File.join(@tmpdir, "history.yml"),
      excluded_urls_path: File.join(@tmpdir, "excluded_urls.yml"),
      author: "Test Author",
      cover_base_image: nil,
      cover_options: {},
      cover_generation_enabled: false,
      lingq_config: nil,
      lingq_enabled: false,
      transcription_language: "sl"
    )
    cfg.min_length_override = min
    cfg.max_length_override = max
    cfg
  end

  def stub_trimmer(called_with)
    fake_trimmer = Object.new
    fake_trimmer.define_singleton_method(:apply_trim) do |path, skip:, cut:, snip:|
      called_with[:skip] = skip
      called_with[:cut] = cut
      called_with[:snip] = snip
      path
    end
    AudioTrimmer.stub(:new, fake_trimmer) do
      yield
    end
  end

  def build_reconcile_pipeline(text, reconciled: false)
    pipeline = build_pipeline
    pipeline.instance_variable_set(:@base_name, "ep")
    pipeline.instance_variable_set(:@reconciled_text, text)
    staging = pipeline.instance_variable_get(:@staging_dir)
    FileUtils.mkdir_p(staging)
    data = { "version" => 1, "engine" => "groq", "intro_duration" => 0.0,
             "segments" => [{ "start" => 0.0, "end" => 1.0, "text" => "raw" }] }
    data["reconciled"] = true if reconciled
    File.write(File.join(staging, "ep_timestamps.json"), JSON.generate(data))
    pipeline
  end

  def with_counting_reconciler(api_key: "test-key-not-real")
    calls = 0
    saved = ENV["ANTHROPIC_API_KEY"]
    api_key.nil? ? ENV.delete("ANTHROPIC_API_KEY") : ENV["ANTHROPIC_API_KEY"] = api_key
    SubtitleReconciler.stub(:reconcile, ->(segs, _text, **) { calls += 1; segs }) { yield }
    calls
  ensure
    saved.nil? ? ENV.delete("ANTHROPIC_API_KEY") : ENV["ANTHROPIC_API_KEY"] = saved
  end

  def capture_fetch_next_kwargs(pipeline)
    passed = nil
    fake_source = Object.new
    fake_source.define_singleton_method(:fetch_next) { |**kw| passed = kw; nil }
    pipeline.instance_variable_set(:@episode_source, fake_source)
    assert_equal 1, pipeline.send(:acquire_rss)
    passed
  end

  def build_pipeline(options: {}, config: nil, name: nil, transcription_language: nil)
    cfg = config || @config
    if name || transcription_language
      cfg = StubConfig.new(**cfg.to_h.merge(
        **(name ? { name: name } : {}),
        **(transcription_language ? { transcription_language: transcription_language } : {})
      ))
    end
    opts = { verbosity: :quiet }.merge(options)
    PodgenCLI::LanguagePipeline.new(
      config: cfg,
      options: opts,
      logger: @logger,
      history: @history,
      today: Date.new(2026, 3, 10)
    )
  end
end
