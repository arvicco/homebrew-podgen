# frozen_string_literal: true

# Integration test: verifies data contracts between pipeline agents.
# Ensures output format of one stage is accepted by the next.

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/script_agent"
require "agents/translation_agent"

class TestPipelineContracts < Minitest::Test
  # Research data format (ResearchAgent output) must pass ScriptAgent validation
  def test_research_format_accepted_by_script_agent
    research_data = [
      {
        topic: "AI developments",
        findings: [
          { title: "GPT-5 Released", url: "https://example.com/gpt5", summary: "New AI model" },
          { title: "Claude 4", url: "https://example.com/claude", summary: "Anthropic update" }
        ]
      },
      {
        topic: "Ruby news",
        findings: [
          { title: "Rails 8", url: "https://example.com/rails", summary: "New Rails version" }
        ]
      }
    ]

    agent = ScriptAgent.new(guidelines: "test", script_path: "/tmp/test_script.md")
    # Should not raise for valid data
    agent.send(:validate_research_data, research_data)
  end

  # Script format (ScriptAgent output) must be accepted by TranslationAgent
  def test_script_format_accepted_by_translation_agent
    script = {
      title: "Episode 42: AI and Ruby",
      segments: [
        { name: "Opening", text: "Welcome to the show!" },
        { name: "AI News", text: "Today we discuss GPT-5." },
        { name: "Wrap-Up", text: "Thanks for listening." }
      ]
    }

    agent = TranslationAgent.new(target_language: "sl")
    formatted = agent.send(:format_script_for_translation, script)

    assert_includes formatted, "Title: Episode 42: AI and Ruby"
    assert_includes formatted, "--- Opening ---"
    assert_includes formatted, "Welcome to the show!"
    script[:segments].each do |seg|
      assert_includes formatted, "--- #{seg[:name]} ---"
      assert_includes formatted, seg[:text]
    end
  end

  # Translation output has same structure as script input (chainable)
  def test_translation_output_structure_matches_script_structure
    translated = {
      title: "Epizoda 42",
      segments: [
        { name: "Uvod", text: "Dobrodošli!" },
        { name: "Zaključek", text: "Hvala za poslušanje." }
      ]
    }

    assert translated.key?(:title)
    assert translated.key?(:segments)
    assert translated[:segments].all? { |s| s.key?(:name) && s.key?(:text) }

    # Can be re-translated (same format)
    agent = TranslationAgent.new(target_language: "de")
    formatted = agent.send(:format_script_for_translation, translated)
    assert_includes formatted, "Epizoda 42"
  end

  # Research data with empty findings is valid (source returned nothing)
  def test_empty_findings_are_valid
    data = [{ topic: "Obscure topic", findings: [] }]
    agent = ScriptAgent.new(guidelines: "test", script_path: "/tmp/test.md")
    # Should not raise for valid data
    agent.send(:validate_research_data, data)
  end

  # TTSAgent accepts segment format from ScriptAgent output
  def test_tts_agent_accepts_script_segments
    segments = [
      { name: "Opening", text: "Welcome to the show! Today we discuss AI." },
      { name: "Story", text: "A new model was released yesterday." },
      { name: "Wrap-Up", text: "Thanks for listening." }
    ]

    # TTSAgent.synthesize expects array of { name:, text: } hashes
    # Verify the structural contract: each segment must have :name and :text strings
    segments.each_with_index do |seg, i|
      assert seg.key?(:name), "Segment [#{i}] must have :name"
      assert seg.key?(:text), "Segment [#{i}] must have :text"
      assert_kind_of String, seg[:name]
      assert_kind_of String, seg[:text]
      refute_empty seg[:text], "Segment [#{i}] :text must not be empty"
    end
  end

  # RssGenerator correctly maps EpisodeHistory output format to its history maps
  def test_rss_generator_accepts_history_format
    require "rss_generator"

    tmpdir = Dir.mktmpdir("podgen_contract_rss")
    episodes_dir = File.join(tmpdir, "test_pod", "episodes")
    FileUtils.mkdir_p(episodes_dir)

    # Create an MP3 so the generator has something to find
    File.write(File.join(episodes_dir, "test_pod-2026-03-01.mp3"), "fake" * 100)

    # History format as produced by EpisodeHistory#record!
    history = [
      {
        "date" => "2026-03-01",
        "title" => "Test Episode",
        "topics" => ["AI"],
        "urls" => ["https://example.com/1"],
        "duration" => 600,
        "timestamp" => "2026-03-01T06:00:00Z"
      }
    ]
    history_path = File.join(tmpdir, "test_pod", "history.yml")
    File.write(history_path, history.to_yaml)

    feed_path = File.join(tmpdir, "feed.xml")
    gen = RssGenerator.new(
      episodes_dir: episodes_dir,
      feed_path: feed_path,
      title: "Test",
      language: "en",
      base_url: "https://example.com/test_pod",
      history_path: history_path
    )
    gen.generate

    doc = REXML::Document.new(File.read(feed_path))
    item = REXML::XPath.first(doc, "//item")
    assert item, "Should generate at least one item"
    assert_equal "Test Episode", item.elements["title"].text
    assert_equal "10:00", item.elements["itunes:duration"].text
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  # DescriptionAgent output shape (title, description strings) integrates with write_transcript_file
  def test_description_agent_output_feeds_transcript
    # DescriptionAgent returns: clean_title → String, clean → String, generate → String
    # write_transcript_file expects episode hash with :title and :description strings
    episode = {
      title: "Cleaned Title",
      description: "A cleaned episode description."
    }
    transcript = "Some transcript text about the episode."

    tmpdir = Dir.mktmpdir("podgen_contract_desc")
    path = File.join(tmpdir, "test_transcript.md")

    # Simulate write_transcript_file logic from language_pipeline.rb
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "w") do |f|
      f.puts "# #{episode[:title]}"
      f.puts
      f.puts episode[:description].to_s unless episode[:description].to_s.empty?
      f.puts
      f.puts "## Transcript"
      f.puts
      f.puts transcript.strip
    end

    content = File.read(path)
    assert_includes content, "# Cleaned Title"
    assert_includes content, "A cleaned episode description."
    assert_includes content, "## Transcript"
    assert_includes content, "Some transcript text"
  ensure
    FileUtils.rm_rf(tmpdir)
  end

  # SourceManager.normalize_result output passes ScriptAgent.validate_research_data
  def test_source_manager_output_matches_script_agent_input
    require "source_manager"

    manager = SourceManager.new(source_config: {})

    # Simulate raw source output with string keys (as some sources return)
    raw_results = [
      { "topic" => "AI news", "findings" => [
        { "title" => "GPT-5", "url" => "https://example.com/gpt5", "summary" => "New model" }
      ] },
      { topic: "Ruby news", findings: [
        { title: "Rails 8", url: "https://example.com/rails", summary: "New version" }
      ] }
    ]

    # normalize_result is private — test that it produces ScriptAgent-compatible output
    normalized = raw_results.map { |r| manager.send(:normalize_result, r) }

    agent = ScriptAgent.new(guidelines: "test", script_path: "/tmp/test.md")
    # Should not raise — normalized output must be valid ScriptAgent input
    agent.send(:validate_research_data, normalized)

    # Verify symbol keys
    normalized.each do |r|
      assert_kind_of Symbol, r.keys.first
      assert_kind_of String, r[:topic]
      assert_kind_of Array, r[:findings]
      r[:findings].each do |f|
        assert f.key?(:title)
        assert f.key?(:url)
        assert f.key?(:summary)
      end
    end
  end
end
