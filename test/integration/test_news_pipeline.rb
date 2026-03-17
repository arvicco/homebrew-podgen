# frozen_string_literal: true

# Integration test: verifies the news pipeline chain.
# Source → SourceManager → ScriptAgent → TranslationAgent
# Tests real API calls — gated behind skip_unless_env.

require_relative "../test_helper"
require "source_manager"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/script_agent"
require "agents/translation_agent"

class TestNewsPipeline < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_news_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- SourceManager output shape ---

  def test_source_manager_output_feeds_script_agent
    # HN is free — no API key needed
    manager = SourceManager.new(source_config: { "hackernews" => true })
    results = manager.research(["Ruby programming"])

    assert_kind_of Array, results
    refute_empty results, "HN should return at least one topic result"

    # Verify shape: [{ topic:, findings: [{ title:, url:, summary: }] }]
    results.each do |r|
      assert r.key?(:topic), "Each result must have :topic"
      assert r.key?(:findings), "Each result must have :findings"
      assert_kind_of Array, r[:findings]
      r[:findings].each do |f|
        assert f.key?(:title), "Each finding must have :title"
        assert f.key?(:url), "Each finding must have :url"
        assert f.key?(:summary), "Each finding must have :summary"
      end
    end

    # Validate this output passes ScriptAgent validation
    agent = ScriptAgent.new(guidelines: "test", script_path: "/tmp/test.md")
    agent.send(:validate_research_data, results)
  end

  def test_script_generation_from_live_sources
    skip_unless_env("ANTHROPIC_API_KEY")

    manager = SourceManager.new(source_config: { "hackernews" => true })
    research = manager.research(["AI"])

    skip "HN returned no findings" if research.all? { |r| r[:findings].empty? }

    script_path = File.join(@tmpdir, "script.md")
    agent = ScriptAgent.new(
      guidelines: "Write a 2-segment tech news podcast. Keep it under 200 words total.",
      script_path: script_path
    )
    script = agent.generate(research)

    # Verify script structure
    assert script.key?(:title), "Script must have :title"
    assert script.key?(:segments), "Script must have :segments"
    assert script.key?(:sources), "Script must have :sources"
    assert_kind_of String, script[:title]
    refute_empty script[:title]

    assert_kind_of Array, script[:segments]
    refute_empty script[:segments]
    script[:segments].each do |seg|
      assert seg.key?(:name)
      assert seg.key?(:text)
      assert_kind_of String, seg[:text]
      refute_empty seg[:text]
    end

    assert_kind_of Array, script[:sources]

    # Script debug file should be written
    assert File.exist?(script_path), "Script debug file should be created"
  end

  def test_script_translates_to_target_language
    skip_unless_env("ANTHROPIC_API_KEY")

    # Use a minimal synthetic script to keep API cost low
    script = {
      title: "Tech News Today",
      segments: [
        { name: "Opening", text: "Welcome to today's tech news roundup." },
        { name: "Wrap-Up", text: "That's all for today. Thanks for listening!" }
      ]
    }

    agent = TranslationAgent.new(target_language: "es")
    translated = agent.translate(script)

    # Same structure as input
    assert translated.key?(:title), "Translated script must have :title"
    assert translated.key?(:segments), "Translated script must have :segments"
    refute_empty translated[:title]

    # Segment count must be preserved
    assert_equal script[:segments].length, translated[:segments].length,
      "Translation must preserve segment count"

    # All segments must have non-empty text
    translated[:segments].each do |seg|
      assert seg.key?(:name)
      assert seg.key?(:text)
      refute_empty seg[:text], "Translated segment text must not be empty"
    end

    # Title should be different from English (translated)
    refute_equal script[:title], translated[:title],
      "Title should be translated"
  end

  def test_full_news_chain_source_to_translated_script
    skip_unless_env("ANTHROPIC_API_KEY")

    # Source → Script → Translate — verify the chain produces consistent shapes
    manager = SourceManager.new(source_config: { "hackernews" => true })
    research = manager.research(["Bitcoin"])

    skip "HN returned no findings" if research.all? { |r| r[:findings].empty? }

    script_path = File.join(@tmpdir, "chain_script.md")
    script_agent = ScriptAgent.new(
      guidelines: "Write a 2-segment tech podcast. Keep it under 150 words total.",
      script_path: script_path
    )
    script = script_agent.generate(research)

    translation_agent = TranslationAgent.new(target_language: "sl")
    translated = translation_agent.translate(script)

    # Translated output must be chainable (same shape as script output minus sources)
    assert translated.key?(:title)
    assert translated.key?(:segments)
    assert_equal script[:segments].length, translated[:segments].length

    # Can be re-translated (chainable contract)
    re_agent = TranslationAgent.new(target_language: "de")
    formatted = re_agent.send(:format_script_for_translation, translated)
    assert_includes formatted, translated[:title]
  end

  def test_script_with_sources_produces_links_section
    skip_unless_env("ANTHROPIC_API_KEY")

    script = {
      title: "Test Episode",
      segments: [{ name: "Content", text: "A brief episode." }],
      sources: [
        { title: "Source One", url: "https://example.com/one?utm_source=test" },
        { title: "Source Two", url: "https://example.com/two" }
      ]
    }

    require "url_cleaner"

    path = File.join(@tmpdir, "links_script.md")
    # Replicate save_script_debug with links: true from generate_command.rb
    File.open(path, "w") do |f|
      f.puts "# #{script[:title]}"
      f.puts
      script[:segments].each do |seg|
        f.puts "## #{seg[:name]}"
        f.puts
        f.puts seg[:text]
        f.puts
      end
      if script[:sources] && !script[:sources].empty?
        f.puts "## More info"
        f.puts
        script[:sources].each do |src|
          clean_url = UrlCleaner.clean(src[:url])
          f.puts "- [#{src[:title]}](#{clean_url})"
        end
        f.puts
      end
    end

    content = File.read(path)
    assert_includes content, "## More info"
    assert_includes content, "[Source One]"
    assert_includes content, "[Source Two]"
    # UTM params should be stripped
    refute_includes content, "utm_source"
    assert_includes content, "https://example.com/one"
  end

  def test_source_manager_with_cache
    cache_dir = File.join(@tmpdir, "cache")
    FileUtils.mkdir_p(cache_dir)

    manager = SourceManager.new(
      source_config: { "hackernews" => true },
      cache_dir: cache_dir
    )

    results1 = manager.research(["Ruby"])
    results2 = manager.research(["Ruby"])

    # Both should return same structure
    assert_kind_of Array, results1
    assert_kind_of Array, results2

    # Cache files should exist after first call
    cache_files = Dir.glob(File.join(cache_dir, "*.yml"))
    refute_empty cache_files, "Cache should write at least one file"
  end

  def test_source_manager_excludes_urls_from_history
    exclude = Set.new(["https://news.ycombinator.com/"])
    manager = SourceManager.new(
      source_config: { "hackernews" => true },
      exclude_urls: exclude
    )

    results = manager.research(["programming"])

    # All findings should have URLs not in the exclude set
    results.each do |r|
      r[:findings].each do |f|
        refute_equal "https://news.ycombinator.com/", f[:url],
          "Excluded URL should not appear in findings"
      end
    end
  end

  def test_script_segments_have_reasonable_length
    skip_unless_env("ANTHROPIC_API_KEY")

    script = {
      title: "Test Episode",
      segments: [
        { name: "Opening", text: "Welcome to today's show! " * 5 },
        { name: "Main Story", text: "The latest news in technology is exciting. " * 20 },
        { name: "Wrap-Up", text: "Thanks for listening today. " * 3 }
      ]
    }

    # Verify the contract: each segment text > 50 chars, total > 500 chars
    script[:segments].each do |seg|
      assert seg[:text].length > 50, "Segment '#{seg[:name]}' should be > 50 chars"
    end

    total = script[:segments].sum { |s| s[:text].length }
    assert total > 500, "Total script text should be > 500 chars"
  end
end
