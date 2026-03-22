# frozen_string_literal: true

require_relative "../test_helper"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/script_agent"

class TestScriptAgent < Minitest::Test
  # --- validate_research_data ---

  def test_validate_valid_data
    agent = build_agent
    # Should not raise for valid data
    agent.send(:validate_research_data, valid_research_data)
  end

  def test_validate_rejects_non_array
    agent = build_agent
    err = assert_raises(ArgumentError) { agent.send(:validate_research_data, "not array") }
    assert_includes err.message, "must be an Array"
  end

  def test_validate_rejects_empty_array
    agent = build_agent
    err = assert_raises(ArgumentError) { agent.send(:validate_research_data, []) }
    assert_includes err.message, "empty"
  end

  def test_validate_rejects_non_hash_item
    agent = build_agent
    assert_raises(ArgumentError) { agent.send(:validate_research_data, ["not a hash"]) }
  end

  def test_validate_rejects_missing_topic
    agent = build_agent
    assert_raises(ArgumentError) do
      agent.send(:validate_research_data, [{ findings: [] }])
    end
  end

  def test_validate_rejects_non_string_topic
    agent = build_agent
    assert_raises(ArgumentError) do
      agent.send(:validate_research_data, [{ topic: 123, findings: [] }])
    end
  end

  def test_validate_rejects_missing_findings
    agent = build_agent
    assert_raises(ArgumentError) do
      agent.send(:validate_research_data, [{ topic: "AI" }])
    end
  end

  def test_validate_rejects_non_array_findings
    agent = build_agent
    assert_raises(ArgumentError) do
      agent.send(:validate_research_data, [{ topic: "AI", findings: "not array" }])
    end
  end

  def test_validate_rejects_finding_missing_keys
    agent = build_agent
    data = [{ topic: "AI", findings: [{ title: "T", url: "U" }] }]
    assert_raises(ArgumentError) { agent.send(:validate_research_data, data) }
  end

  # --- format_research ---

  def test_format_research
    agent = build_agent
    result = agent.send(:format_research, valid_research_data)
    assert_includes result, "## AI news"
    assert_includes result, "GPT-5 Released"
    assert_includes result, "https://example.com/gpt5"
    assert_includes result, "GPT-5 launches with new features"
  end

  def test_format_research_handles_nil_fields
    agent = build_agent
    data = [{ topic: nil, findings: [{ title: nil, url: nil, summary: nil }] }]
    result = agent.send(:format_research, data)
    assert_includes result, "Unknown topic"
    assert_includes result, "Untitled"
    assert_includes result, "no URL"
    assert_includes result, "No summary available"
  end

  # --- generate ---

  def test_generate_returns_script_hash
    agent = build_agent
    stub_client(agent, title: "Episode 1", segments: [{ name: "Opening", text: "Hello!" }])

    result = agent.generate(valid_research_data)
    assert_equal "Episode 1", result[:title]
    assert_equal 1, result[:segments].length
    assert_equal "Opening", result[:segments].first[:name]
    assert_equal "Hello!", result[:segments].first[:text]
  end

  def test_generate_returns_sources
    agent = build_agent
    stub_client(agent, title: "Episode 1", segments: [{ name: "Opening", text: "Hello!" }],
                sources: [{ title: "GPT-5 launches", url: "https://example.com/gpt5" }])

    result = agent.generate(valid_research_data)
    assert_equal 1, result[:sources].length
    assert_equal "GPT-5 launches", result[:sources].first[:title]
    assert_equal "https://example.com/gpt5", result[:sources].first[:url]
  end

  def test_generate_returns_empty_sources_when_none
    agent = build_agent
    stub_client(agent, title: "Episode 1", segments: [{ name: "Opening", text: "Hello!" }])

    result = agent.generate(valid_research_data)
    assert_equal [], result[:sources]
  end

  def test_generate_saves_debug_file
    agent = build_agent
    stub_client(agent, title: "Episode 1", segments: [{ name: "Intro", text: "Welcome" }])

    agent.generate(valid_research_data)
    assert File.exist?(@script_path), "Script debug file should be saved"

    content = File.read(@script_path)
    assert_includes content, "# Episode 1"
    assert_includes content, "## Intro"
    assert_includes content, "Welcome"
  end

  def test_generate_raises_on_nil_parsed_output
    agent = build_agent
    stub_client(agent, nil_output: true)

    err = assert_raises(RuntimeError) { agent.generate(valid_research_data) }
    assert_includes err.message, "Structured output parsing failed"
  end

  def test_system_prompt_includes_todays_date_with_day_of_week
    agent = build_agent
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    system = client.last_call[:system]
    prompt_text = system.map { |s| s[:text] }.join("\n")

    today_day = Date.today.strftime("%A")
    assert_includes prompt_text, "today's date is"
    assert_includes prompt_text, today_day
    assert_match(/\d{4}-\d{2}-\d{2}/, prompt_text)
  end

  def test_system_prompt_includes_guidelines_with_cache_control
    agent = build_agent
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    system = client.last_call[:system]
    cached_block = system.find { |s| s[:cache_control] }
    assert_equal "Test guidelines", cached_block[:text]
  end

  def test_system_prompt_without_priority_urls_has_no_priority_instruction
    agent = build_agent
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    system = client.last_call[:system]
    prompt_text = system.map { |s| s[:text] }.join("\n")
    refute_includes prompt_text, "PRIORITY LINKS"
  end

  def test_system_prompt_with_priority_urls_includes_priority_instruction
    agent = ScriptAgent.new(
      guidelines: "Test guidelines",
      script_path: @script_path,
      priority_urls: ["https://example.com/priority"]
    )
    agent.define_singleton_method(:sleep) { |_| }
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    system = client.last_call[:system]
    prompt_text = system.map { |s| s[:text] }.join("\n")
    assert_includes prompt_text, "PRIORITY LINKS"
    assert_includes prompt_text, "MUST cover every priority link"
  end

  def test_generate_returns_per_segment_sources
    agent = build_agent
    seg_sources = [MockSource.new("GPT-5 launches", "https://example.com/gpt5")]
    segs = [MockSegment.new("AI News", "Hello!", seg_sources)]
    output = MockScript.new("Episode 1", segs, [])
    client = MockClient.new(output)
    agent.instance_variable_set(:@client, client)

    result = agent.generate(valid_research_data)
    assert_equal 1, result[:segments].first[:sources].length
    assert_equal "GPT-5 launches", result[:segments].first[:sources].first[:title]
  end

  def test_generate_omits_segment_sources_when_nil
    agent = build_agent
    stub_client(agent, title: "Episode 1", segments: [{ name: "Opening", text: "Hello!" }])

    result = agent.generate(valid_research_data)
    refute result[:segments].first.key?(:sources)
  end

  def test_system_prompt_with_inline_links_includes_per_segment_instruction
    agent = ScriptAgent.new(
      guidelines: "Test", script_path: @script_path,
      links_config: { show: true, position: "inline" }
    )
    agent.define_singleton_method(:sleep) { |_| }
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    prompt_text = client.last_call[:system].map { |s| s[:text] }.join("\n")
    assert_includes prompt_text, "SOURCE ATTRIBUTION"
    assert_includes prompt_text, "sources"
  end

  def test_system_prompt_with_bottom_links_has_no_per_segment_instruction
    agent = ScriptAgent.new(
      guidelines: "Test", script_path: @script_path,
      links_config: { show: true, position: "bottom" }
    )
    agent.define_singleton_method(:sleep) { |_| }
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    prompt_text = client.last_call[:system].map { |s| s[:text] }.join("\n")
    refute_includes prompt_text, "SOURCE ATTRIBUTION"
  end

  def test_system_prompt_with_max_includes_limit_instruction
    agent = ScriptAgent.new(
      guidelines: "Test", script_path: @script_path,
      links_config: { show: true, max: 5 }
    )
    agent.define_singleton_method(:sleep) { |_| }
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    prompt_text = client.last_call[:system].map { |s| s[:text] }.join("\n")
    assert_includes prompt_text, "SOURCE LIMIT"
    assert_includes prompt_text, "5 source links total"
  end

  def test_system_prompt_with_max_and_inline_says_per_segment
    agent = ScriptAgent.new(
      guidelines: "Test", script_path: @script_path,
      links_config: { show: true, position: "inline", max: 3 }
    )
    agent.define_singleton_method(:sleep) { |_| }
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    prompt_text = client.last_call[:system].map { |s| s[:text] }.join("\n")
    assert_includes prompt_text, "3 source links per segment"
  end

  def test_priority_urls_defaults_to_empty
    agent = build_agent
    client = stub_client(agent, title: "T", segments: [])

    agent.generate(valid_research_data)
    system = client.last_call[:system]
    prompt_text = system.map { |s| s[:text] }.join("\n")
    refute_includes prompt_text, "PRIORITY"
  end

  def setup
    @tmpdir = Dir.mktmpdir("podgen_test")
    @script_path = File.join(@tmpdir, "script.md")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  private

  def valid_research_data
    [{
      topic: "AI news",
      findings: [{
        title: "GPT-5 Released",
        url: "https://example.com/gpt5",
        summary: "GPT-5 launches with new features"
      }]
    }]
  end

  def build_agent
    agent = ScriptAgent.new(guidelines: "Test guidelines", script_path: @script_path)
    agent.define_singleton_method(:sleep) { |_| }
    agent
  end

  def stub_client(agent, title: nil, segments: nil, sources: nil, nil_output: false)
    output = if nil_output
      nil
    else
      segs = (segments || []).map { |s| MockSegment.new(s[:name], s[:text]) }
      srcs = (sources || []).map { |s| MockSource.new(s[:title], s[:url]) }
      MockScript.new(title, segs, srcs)
    end
    client = MockClient.new(output)
    agent.instance_variable_set(:@client, client)
    client
  end

  MockSegment = Struct.new(:name, :text, :sources)
  MockSource = Struct.new(:title, :url)
  MockScript = Struct.new(:title, :segments, :sources)

  class MockClient
    attr_reader :calls
    def initialize(output) = (@output = output; @calls = [])
    def messages = self
    def last_call = @calls.last
    def create(**kw) = (@calls << kw; MockMsg.new(@output))
  end

  class MockMsg
    def initialize(output) = @output = output
    def parsed_output = @output
    def stop_reason = "end_turn"
    def usage = MockUsage.new
  end

  class MockUsage
    def input_tokens = 500
    def output_tokens = 200
    def cache_creation_input_tokens = 0
    def cache_read_input_tokens = 0
  end
end
