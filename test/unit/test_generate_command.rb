# frozen_string_literal: true

require_relative "../test_helper"
require "cli/generate_command"
require "script_artifact"

class TestGenerateCommand < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_gen_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    ENV.delete("PODGEN_ROOT")
    FileUtils.rm_rf(@tmpdir)
  end

  # --- save_script_debug ---

  def test_save_script_debug_basic
    cmd = build_command
    script = {
      title: "Test Episode",
      segments: [
        { name: "Opening", text: "Welcome to the show." },
        { name: "Topic", text: "Today we discuss AI." }
      ],
      sources: []
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger)

    content = File.read(path)
    assert_includes content, "# Test Episode"
    assert_includes content, "## Opening"
    assert_includes content, "Welcome to the show."
    assert_includes content, "## Topic"
  end

  def test_save_script_debug_bottom_links
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{ name: "Main", text: "Content." }],
      sources: [
        { title: "Example Article", url: "https://example.com/article?utm_source=twitter" }
      ]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true })

    content = File.read(path)
    assert_includes content, "## More info"
    assert_includes content, "[Example Article]"
    refute_includes content, "utm_source"
    assert_includes content, "https://example.com/article"
  end

  def test_save_script_debug_bottom_links_custom_title
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{ name: "Main", text: "Content." }],
      sources: [{ title: "Source", url: "https://example.com" }]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, title: "Read more" })

    content = File.read(path)
    assert_includes content, "## Read more"
    refute_includes content, "## More info"
  end

  def test_save_script_debug_bottom_links_with_max
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{ name: "Main", text: "Content." }],
      sources: [
        { title: "Source 1", url: "https://example.com/1" },
        { title: "Source 2", url: "https://example.com/2" },
        { title: "Source 3", url: "https://example.com/3" }
      ]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, max: 2 })

    content = File.read(path)
    assert_includes content, "Source 1"
    assert_includes content, "Source 2"
    refute_includes content, "Source 3"
  end

  def test_save_script_debug_inline_links
    cmd = build_command
    script = {
      title: "Episode",
      segments: [
        { name: "AI News", text: "GPT-5 launched.", sources: [{ title: "GPT-5", url: "https://example.com/gpt5" }] },
        { name: "Wrap-Up", text: "Thanks for listening." }
      ],
      sources: [{ title: "GPT-5", url: "https://example.com/gpt5" }]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, position: "inline" })

    content = File.read(path)
    # Links appear after their segment, not in a bottom section
    assert_includes content, "[GPT-5]"
    refute_includes content, "## More info"
    # Links should be after the segment text, before the next segment
    ai_pos = content.index("GPT-5 launched.")
    link_pos = content.index("[GPT-5]")
    wrapup_pos = content.index("## Wrap-Up")
    assert link_pos > ai_pos
    assert link_pos < wrapup_pos
  end

  def test_save_script_debug_inline_links_with_max
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{
        name: "News", text: "Content.",
        sources: [
          { title: "S1", url: "https://example.com/1" },
          { title: "S2", url: "https://example.com/2" },
          { title: "S3", url: "https://example.com/3" }
        ]
      }],
      sources: []
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, position: "inline", max: 1 })

    content = File.read(path)
    assert_includes content, "S1"
    refute_includes content, "S2"
  end

  def test_save_script_debug_inline_skips_segments_without_sources
    cmd = build_command
    script = {
      title: "Episode",
      segments: [
        { name: "Opening", text: "Welcome." },
        { name: "News", text: "Content.", sources: [{ title: "S1", url: "https://example.com" }] }
      ],
      sources: []
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: { show: true, position: "inline" })

    content = File.read(path)
    # Only one link list, after News segment
    assert_equal 1, content.scan(/\[S1\]/).length
  end

  def test_save_script_debug_without_links
    cmd = build_command
    script = {
      title: "Episode",
      segments: [{ name: "Main", text: "Content." }],
      sources: [{ title: "Source", url: "https://example.com" }]
    }
    path = File.join(@episodes_dir, "test_script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger, links_config: nil)

    content = File.read(path)
    refute_includes content, "## More info"
    refute_includes content, "example.com"
  end

  def test_save_script_debug_creates_directory
    cmd = build_command
    script = { title: "Test", segments: [], sources: [] }
    path = File.join(@episodes_dir, "sub", "dir", "script.md")
    logger = StubGenLogger.new

    cmd.send(:save_script_debug, script, path, logger)

    assert File.exist?(path)
  end

  # --- surface_guidelines_warnings ---

  def test_surface_guidelines_warnings_prints_to_stderr
    cmd = build_command
    config = Struct.new(:parser_warnings).new(["Transcription Engine: unknown engine code 'whisper'"])

    _out, err = capture_io { cmd.send(:surface_guidelines_warnings, config) }

    assert_match(/guidelines\.md/, err)
    assert_match(/whisper/, err)
  end

  def test_surface_guidelines_warnings_silent_when_clean
    cmd = build_command
    config = Struct.new(:parser_warnings).new([])

    _out, err = capture_io { cmd.send(:surface_guidelines_warnings, config) }

    assert_empty err
  end

  def test_surface_guidelines_warnings_reaches_stderr_with_real_config
    # End-to-end through PodcastConfig → GuidelinesParser: warnings are
    # appended during lazy section parsing, so this fails if the surfacing
    # point reads them before the sections are primed.
    podcast_dir = File.join(@tmpdir, "podcasts", "warnpod")
    FileUtils.mkdir_p(podcast_dir)
    File.write(File.join(podcast_dir, "guidelines.md"), <<~MD)
      ## Podcast
      - name: Warn Pod

      ## Transcription Engine
      - whisper
    MD
    prev_root = ENV["PODGEN_ROOT"]
    ENV["PODGEN_ROOT"] = @tmpdir
    require "podcast_config"
    config = PodcastConfig.new("warnpod")

    _out, err = capture_io { build_command.send(:surface_guidelines_warnings, config) }

    assert_match(/whisper/, err)
    assert_match(/guidelines\.md/, err)
  ensure
    prev_root ? ENV["PODGEN_ROOT"] = prev_root : ENV.delete("PODGEN_ROOT")
  end

  # --- verify_ffmpeg! ---

  def test_verify_ffmpeg_success
    cmd = build_command
    logger = StubGenLogger.new

    # Should not raise if ffmpeg is available
    if system("which ffmpeg > /dev/null 2>&1")
      cmd.send(:verify_ffmpeg!, logger) # no error
    else
      assert_raises(RuntimeError) { cmd.send(:verify_ffmpeg!, logger) }
    end
  end

  # --- preflight_network! (P1-13) ---

  def test_preflight_network_raises_before_any_phase_when_network_is_dead
    cmd = build_command
    logger = StubGenLogger.new

    Connectivity.stub(:preflight!, ->(**) { raise Connectivity::PreflightError, "no network: cannot resolve x" }) do
      err = assert_raises(Connectivity::PreflightError) { cmd.send(:preflight_network!, logger) }
      assert_includes err.message, "no network"
    end
  end

  def test_preflight_network_passes_when_connectivity_ok
    cmd = build_command
    logger = StubGenLogger.new

    Connectivity.stub(:preflight!, nil) do
      assert_nil cmd.send(:preflight_network!, logger)
    end
  end

  # --- inject_priority_links ---

  def test_inject_priority_links_returns_unchanged_when_no_links_file
    cmd = build_command
    cmd.instance_variable_set(:@dry_run, false)
    cmd.instance_variable_set(:@logger, StubGenLogger.new)

    # Point to nonexistent file — PriorityLinks will be empty
    config = Struct.new(:links_path).new(File.join(@tmpdir, "nonexistent_links.md"))
    cmd.instance_variable_set(:@config, config)

    research = [{ topic: "AI", findings: [{ title: "Article", url: "https://example.com" }] }]
    result_data, priority_urls = cmd.send(:inject_priority_links, research)

    assert_equal 1, result_data.length
    assert_equal "AI", result_data.first[:topic]
    assert_empty priority_urls
  end

  # CRPR r2 W1: a dead link (404) reaches neither research_data nor
  # priority_urls, and finalize consumes it; a transient one (502) stays.
  def test_priority_links_dead_link_consumed_without_injection_transient_stays
    cmd = build_command
    cmd.instance_variable_set(:@dry_run, false)
    cmd.instance_variable_set(:@logger, StubGenLogger.new)
    links_path = File.join(@tmpdir, "links.yml")
    config = Struct.new(:links_path, :primary_language, :history_path).new(links_path, "en", File.join(@tmpdir, "history.yml"))
    cmd.instance_variable_set(:@config, config)
    links = PriorityLinks.new(links_path)
    %w[https://live.example.com/a https://dead.example.com/b https://flaky.example.com/c].each { |u| links.add(u) }
    responses = {
      "live.example.com" => Struct.new(:code, :body) { def [](_) = nil }.new("200", "<title>Live</title>"),
      "dead.example.com" => Struct.new(:code, :body) { def [](_) = nil }.new("404", ""),
      "flaky.example.com" => Struct.new(:code, :body) { def [](_) = nil }.new("502", "")
    }

    research_data, priority_urls = Net::HTTP.stub(:start, ->(host, *_a, **_k) { responses.fetch(host) }) do
      cmd.send(:inject_priority_links, [])
    end

    assert_equal ["https://live.example.com/a"], priority_urls
    assert_equal ["https://live.example.com/a"], research_data.flat_map { |r| r[:findings].map { |f| f[:url] } }

    cmd.instance_variable_set(:@history, Object.new.tap { |h| h.define_singleton_method(:record!) { |**| nil } })
    cmd.instance_variable_set(:@base_name, "pod-2026-10-16")
    cmd.instance_variable_set(:@pipeline_start, Time.now)
    cmd.instance_variable_set(:@warnings, [])
    script = {title: "T", segments: [], sources: []}
    AudioAssembler.stub(:probe_duration, 60.0) do
      capture_io { cmd.send(:finalize, [File.join(@tmpdir, "pod-2026-10-16.mp3")], script, research_data, priority_urls) }
    end

    assert_equal ["https://flaky.example.com/c"], PriorityLinks.new(links_path).all.map { |e| e["url"] }
  end

  # CRPR r3 nit: when every queued link fails, no empty "Priority links"
  # topic reaches the script prompt or the history's covered topics.
  def test_inject_priority_links_all_failed_adds_no_topic
    cmd = build_command
    cmd.instance_variable_set(:@dry_run, false)
    cmd.instance_variable_set(:@logger, StubGenLogger.new)
    links_path = File.join(@tmpdir, "links.yml")
    cmd.instance_variable_set(:@config, Struct.new(:links_path).new(links_path))
    links = PriorityLinks.new(links_path)
    %w[https://dead.example.com/b https://flaky.example.com/c].each { |u| links.add(u) }
    responses = {
      "dead.example.com" => Struct.new(:code, :body) { def [](_) = nil }.new("404", ""),
      "flaky.example.com" => Struct.new(:code, :body) { def [](_) = nil }.new("502", "")
    }
    research = [{topic: "AI", findings: []}]

    research_data, priority_urls = Net::HTTP.stub(:start, ->(host, *_a, **_k) { responses.fetch(host) }) do
      cmd.send(:inject_priority_links, research)
    end

    assert_equal ["AI"], research_data.map { |r| r[:topic] }
    assert_empty priority_urls
  end

  # CRPR r3 nit: dead links are consumed only by finalize; a run that fails
  # before it leaves them queued.
  def test_run_failure_before_finalize_leaves_dead_link_queued
    cmd = runnable_command("news")
    cmd.singleton_class.remove_method(:inject_priority_links)
    links_path = File.join(@tmpdir, "links.yml")
    cmd.instance_variable_set(:@config, Struct.new(:type, :links_path).new("news", links_path))
    PriorityLinks.new(links_path).add("https://dead.example.com/b")
    cmd.define_singleton_method(:produce_episodes) { |*| raise "TTS quota" }
    dead = Struct.new(:code, :body) { def [](_) = nil }.new("404", "")

    code = nil
    Net::HTTP.stub(:start, ->(*_a, **_k) { dead }) { capture_io { code = cmd.run } }

    assert_equal 1, code
    # The link was fetched and classified dead — not merely never fetched.
    assert_equal ["https://dead.example.com/b"], cmd.instance_variable_get(:@dead_priority_urls)
    assert_equal ["https://dead.example.com/b"], PriorityLinks.new(links_path).all.map { |e| e["url"] }
  end

  def test_inject_priority_links_skips_on_dry_run
    cmd = build_command
    cmd.instance_variable_set(:@dry_run, true)
    cmd.instance_variable_set(:@logger, StubGenLogger.new)

    links_path = File.join(@tmpdir, "links.md")
    File.write(links_path, "- [Test](https://example.com) note\n")
    config = Struct.new(:links_path).new(links_path)
    cmd.instance_variable_set(:@config, config)

    research = [{ topic: "AI", findings: [] }]
    result_data, priority_urls = cmd.send(:inject_priority_links, research)

    assert_equal 1, result_data.length
    assert_empty priority_urls
  end

  # --- P3-1: TopicAgent hn_queries reach the HN source ---

  def test_generate_then_research_threads_topic_agent_hn_queries_to_source_manager
    cmd = build_command
    cmd.instance_variable_set(:@dry_run, false)
    cmd.instance_variable_set(:@logger, StubGenLogger.new)
    cmd.instance_variable_set(:@history, Struct.new(:recent_topics_summary, :recent_urls).new(nil, Set.new))
    config = Struct.new(:episodes_dir, :sources).new(@episodes_dir, { "hackernews" => true })
    cmd.instance_variable_set(:@config, config)

    keywords = { "Long research topic October 2026" => "research topic" }
    fake_agent = Struct.new(:generate, :hn_queries).new(["Long research topic October 2026"], keywords)
    manager_kwargs = nil
    fake_manager = Object.new
    fake_manager.define_singleton_method(:research) { |topics| topics.map { |t| { topic: t, findings: [{ url: "https://e.x/1" }] } } }

    TopicAgent.stub(:new, fake_agent) do
      SourceManager.stub(:new, ->(**kw) { (manager_kwargs = kw) && fake_manager }) do
        topics = cmd.send(:generate_topics)
        cmd.send(:research_topics, topics)
      end
    end

    assert_equal keywords, manager_kwargs[:hn_queries]
  end

  # --- P7-0: every run ends its log with one RUN-OUTCOME line ---

  def test_run_news_with_warnings_ends_log_with_warn_outcome
    cmd = runnable_command("news")
    cmd.define_singleton_method(:produce_episodes) do |_script, _research|
      @logger.error("Language es failed: RuntimeError: x")
      @warnings << "Language es failed: RuntimeError: x"
      ["/x/pod-2026-10-10.mp3"]
    end
    code = nil
    capture_io { code = cmd.run }

    assert_equal 0, code
    assert_equal "RUN-OUTCOME status=warn warnings=1 errors=1 first=Language es failed: RuntimeError: x", last_log_line
  end

  def test_run_news_clean_ends_log_with_ok_outcome
    cmd = runnable_command("news")
    capture_io { cmd.run }

    assert_equal "RUN-OUTCOME status=ok warnings=0 errors=0", last_log_line
  end

  def test_run_news_failure_ends_log_with_error_outcome
    cmd = runnable_command("news")
    cmd.define_singleton_method(:generate_script) { |*| raise "TTS quota" }
    code = nil
    capture_io { code = cmd.run }

    assert_equal 1, code
    assert_equal "RUN-OUTCOME status=error warnings=0 errors=2 first=RuntimeError: TTS quota", last_log_line
  end

  def test_run_language_pipeline_outcome_counts_pipeline_warnings
    cmd = runnable_command("language")
    fake = Struct.new(:warnings) { def run = 0 }.new(["Vocabulary annotation failed (RuntimeError: v)"])
    code = nil
    PodgenCLI::LanguagePipeline.stub(:new, fake) { capture_io { code = cmd.run } }

    assert_equal 0, code
    assert_equal "RUN-OUTCOME status=warn warnings=1 errors=0 first=Vocabulary annotation failed (RuntimeError: v)",
      last_log_line
  end

  def test_run_outcome_counts_logged_library_warnings
    cmd = runnable_command("news")
    cmd.define_singleton_method(:research_topics) do |_|
      @logger.warning("[ResearchAgent] Warning: Failed to research 'x' after 3 attempts: 401")
      []
    end
    capture_io { cmd.run }

    assert_equal "RUN-OUTCOME status=warn warnings=1 errors=0 " \
      "first=[ResearchAgent] Warning: Failed to research 'x' after 3 attempts: 401", last_log_line
  end

  def test_generate_topics_fallback_to_queue_is_a_run_warning
    cmd = build_command
    cmd.instance_variable_set(:@dry_run, false)
    cmd.instance_variable_set(:@logger, StubGenLogger.new)
    cmd.instance_variable_set(:@warnings, [])
    cmd.instance_variable_set(:@history, Struct.new(:recent_topics_summary).new(nil))
    cmd.instance_variable_set(:@config, Struct.new(:queue_topics).new(["q1"]))

    topics = TopicAgent.stub(:new, ->(**) { raise "401 revoked" }) { cmd.send(:generate_topics) }

    assert_equal ["q1"], topics
    assert_equal ["Topic generation failed (RuntimeError: 401 revoked), fell back to queue.yml"],
      cmd.instance_variable_get(:@warnings)
  end

  # --- P8-1: minimum-research guard (Q-69) ---

  def test_run_news_topic_without_findings_dropped_from_script_input_with_warning
    cmd = researching_command({ "t1" => [{ title: "A", url: "https://e.x/a", summary: "s" }], "t2" => [] })
    script_input = nil
    cmd.define_singleton_method(:generate_script) { |_t, research, _p| (script_input = research) && { title: "T", segments: [] } }
    code = run_with_fake_sources(cmd)

    assert_equal 0, code
    assert_equal ["t1"], script_input.map { |r| r[:topic] }
    assert_includes cmd.instance_variable_get(:@warnings), "Warning: topic 't2' dropped — no research findings"
    assert_match(/\ARUN-OUTCOME status=warn warnings=1 /, last_log_line)
  end

  def test_run_news_topic_missing_from_research_counts_as_dropped
    cmd = researching_command({ "t1" => [{ title: "A", url: "https://e.x/a", summary: "s" }] }, topics: %w[t1 t2])
    run_with_fake_sources(cmd)

    assert_includes cmd.instance_variable_get(:@warnings), "Warning: topic 't2' dropped — no research findings"
  end

  def test_run_news_no_findings_for_any_topic_fails_before_script_agent
    cmd = researching_command({ "t1" => [], "t2" => [] })
    script_called = false
    cmd.define_singleton_method(:generate_script) { |*| (script_called = true) && { title: "T", segments: [] } }
    code = run_with_fake_sources(cmd)

    assert_equal 1, code
    refute script_called, "ScriptAgent must not run without research findings"
    assert File.read(@log_path).match?(/END Research \(/), "the Research phase is closed before the fatal"
    assert_match(/\ARUN-OUTCOME status=error .*first=RuntimeError: no research findings for any topic/, last_log_line)
  end

  def test_language_pipeline_warnings_reader_exposes_collected_warnings
    pipeline = PodgenCLI::LanguagePipeline.allocate
    pipeline.instance_variable_set(:@warnings, ["w1"])
    assert_equal ["w1"], pipeline.warnings
  end

  # parse_saved_script + strip_trailing_link_list extracted into LegacyScriptParser;
  # see test_legacy_script_parser.rb

  # --- save_script_debug writes JSON alongside markdown ---

  def test_save_script_debug_writes_canonical_json_alongside_md
    cmd = build_command
    script = {
      title: "Episode",
      segments: [
        { name: "News", text: "Big story.", sources: [{ title: "S1", url: "https://example.com/1" }] },
        { name: "Wrap-Up", text: "Thanks." }
      ],
      sources: [{ title: "S1", url: "https://example.com/1" }]
    }
    md_path = File.join(@episodes_dir, "ep_script.md")
    cmd.send(:save_script_debug, script, md_path, StubGenLogger.new,
             links_config: { show: true, position: "inline" })

    json_path = ScriptArtifact.json_path_for(md_path)
    assert File.exist?(json_path), "Expected JSON written next to markdown"

    parsed = ScriptArtifact.read(json_path)
    assert_equal "Episode", parsed[:title]
    # Per-segment sources preserved in JSON (not stripped like markdown round-trip)
    assert_equal [{ title: "S1", url: "https://example.com/1" }], parsed[:segments][0][:sources]
  end

  # write_sources extracted into ScriptRenderer; see test_script_renderer.rb

  # --- primary language from config (P7-6) ---

  def test_produce_episodes_sl_primary_names_sl_bare_and_en_suffixed
    cmd, config = build_sl_en_command
    voiced = []
    translated_to = []
    fake_voicer = Object.new
    fake_voicer.define_singleton_method(:voice) { |output_path:, lang_code:, **| voiced << [File.basename(output_path), lang_code] }
    translator_new = lambda do |target_language:, **|
      translated_to << target_language
      Object.new.tap { |t| t.define_singleton_method(:translate) { |s| s.merge(title: "EN #{s[:title]}") } }
    end

    paths = nil
    Voicer.stub(:new, ->(**) { fake_voicer }) do
      TranslationAgent.stub(:new, translator_new) do
        capture_io { paths = cmd.send(:produce_episodes, sl_script, []) }
      end
    end

    assert_equal [["mypod-2026-01-15.mp3", "sl"], ["mypod-2026-01-15-en.mp3", "en"]], voiced
    assert_equal ["en"], translated_to, "the primary (sl) script is voiced as-is; only en is translated"
    assert_equal %w[mypod-2026-01-15.mp3 mypod-2026-01-15-en.mp3], paths.map { |p| File.basename(p) }
    assert File.exist?(File.join(config.episodes_dir, "mypod-2026-01-15-en_script.md"))
  end

  def test_finalize_sl_primary_records_sl_and_en_language_keys
    cmd, config = build_sl_en_command
    recorded = nil
    history = Object.new
    history.define_singleton_method(:record!) { |**kw| recorded = kw }
    cmd.instance_variable_set(:@history, history)
    cmd.instance_variable_set(:@base_name, "mypod-2026-01-15")
    cmd.instance_variable_set(:@pipeline_start, Time.now)
    cmd.instance_variable_set(:@warnings, [])
    paths = %w[mypod-2026-01-15 mypod-2026-01-15-en].map { |b| File.join(config.episodes_dir, "#{b}.mp3") }

    AudioAssembler.stub(:probe_duration, 61.0) do
      capture_io { cmd.send(:finalize, paths, sl_script, [], []) }
    end

    assert_equal %w[sl en], recorded[:languages].keys
  end

  private

  def sl_script
    { title: "Naslov", segments: [{ name: "Uvod", text: "Dober dan." }], sources: [] }
  end

  def build_sl_en_command
    require "podcast_config"
    FileUtils.mkdir_p(File.join(@tmpdir, "podcasts", "mypod"))
    File.write(File.join(@tmpdir, "podcasts", "mypod", "guidelines.md"),
      "## Podcast\n- name: mypod\n- language:\n  - sl\n  - en\n")
    ENV["PODGEN_ROOT"] = @tmpdir
    config = PodcastConfig.new("mypod")
    FileUtils.mkdir_p(config.episodes_dir)
    cmd = build_command
    cmd.instance_variable_set(:@config, config)
    cmd.instance_variable_set(:@logger, StubGenLogger.new)
    cmd.instance_variable_set(:@options, {verbosity: :quiet})
    cmd.instance_variable_set(:@today, Date.new(2026, 1, 15))
    cmd.instance_variable_set(:@warnings, [])
    [cmd, config]
  end

  class StubGenLogger
    attr_reader :messages

    def initialize = @messages = []
    def log(msg) = @messages << msg
    def error(msg) = @messages << msg
    def phase_start(_) = nil
    def phase_end(_) = nil
  end

  def build_command
    PodgenCLI::GenerateCommand.allocate
  end

  # A command past setup_pipeline whose phases are stubbed: run's own control
  # flow (and its RUN-OUTCOME line) is what's exercised.
  def runnable_command(type)
    cmd = build_command
    @log_path = File.join(@tmpdir, "run.log")
    cmd.instance_variable_set(:@options, {verbosity: :quiet})
    cmd.instance_variable_set(:@dry_run, false)
    cmd.instance_variable_set(:@podcast_name, "pod")
    cmd.instance_variable_set(:@config, Struct.new(:type).new(type))
    cmd.instance_variable_set(:@logger, PodcastAgent::Logger.new(log_path: @log_path, verbosity: :quiet))
    cmd.instance_variable_set(:@lock_file, File.open(File.join(@tmpdir, "run.lock"), File::RDWR | File::CREAT))
    cmd.instance_variable_set(:@warnings, [])
    cmd.define_singleton_method(:setup_pipeline) { nil }
    cmd.define_singleton_method(:verify_ffmpeg!) { |_| nil }
    cmd.define_singleton_method(:preflight_network!) { |_| nil }
    cmd.define_singleton_method(:generate_topics) { ["t"] }
    cmd.define_singleton_method(:research_topics) { |_| [] }
    cmd.define_singleton_method(:inject_priority_links) { |r| [r, []] }
    cmd.define_singleton_method(:generate_script) { |*| {title: "T", segments: []} }
    cmd.define_singleton_method(:review_script) { |s, *| s }
    cmd.define_singleton_method(:produce_episodes) { |*| ["/x/pod-2026-10-10.mp3"] }
    cmd.define_singleton_method(:finalize) { |*| nil }
    cmd
  end

  # runnable_command with the real research_topics; run it inside
  # run_with_fake_sources so SourceManager.new yields a fake
  # returning `findings_by_topic` (a topic absent from the hash is absent
  # from the research data, as when every source failed).
  def run_with_fake_sources(cmd)
    code = nil
    SourceManager.stub(:new, ->(**) { @fake_sources }) { capture_io { code = cmd.run } }
    code
  end

  def researching_command(findings_by_topic, topics: findings_by_topic.keys)
    cmd = runnable_command("news")
    cmd.singleton_class.send(:remove_method, :research_topics)
    cmd.define_singleton_method(:generate_topics) { topics }
    cmd.instance_variable_set(:@config, Struct.new(:type, :episodes_dir, :sources).new("news", @episodes_dir, {}))
    cmd.instance_variable_set(:@history, Struct.new(:recent_urls).new(Set.new))
    manager = Object.new
    manager.define_singleton_method(:research) { |_| findings_by_topic.map { |t, f| { topic: t, findings: f } } }
    @fake_sources = manager
    cmd
  end

  def last_log_line
    File.readlines(@log_path, chomp: true).last.sub(/\A\[[^\]]*\] /, "")
  end
end
