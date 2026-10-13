# frozen_string_literal: true

require_relative "../test_helper"
require "claude_models"

ENV["ANTHROPIC_API_KEY"] ||= "test-key"
require "agents/topic_agent"
require "agents/script_agent"
require "agents/script_reviewer"
require "agents/translation_agent"
require "transcription/transcript_merger"
require "subtitle_reconciler"
require "vocabulary_annotator"
require "image_ranker"
require "sources/claude_web_source"
require "tell/translator"
require "tell/glosser"

# P6-0 (Q-55): a CLAUDE_EFFORT_<ROLE> override reaches every Claude call
# site, and structured-output callers keep their output_config[:format].
class TestEffortWiring < Minitest::Test
  class Captured < StandardError; end

  # Records the kwargs of messages.create, then stops the caller.
  class RecordingClient
    attr_reader :calls

    def initialize = @calls = []
    def messages = self

    def create(**kw)
      @calls << kw
      raise Captured
    end
  end

  def setup
    @saved = ENV.to_h.select { |k, _| k.start_with?("CLAUDE_") }
    @saved.each_key { |k| ENV.delete(k) }
  end

  def teardown
    ENV.keys.select { |k| k.start_with?("CLAUDE_") }.each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
  end

  # role => [structured format class or nil, lambda(client) driving one call]
  SITES = {
    topic: [TopicList, ->(c) {
      agent = TopicAgent.new(guidelines: "g")
      agent.instance_variable_set(:@client, c)
      agent.generate
    }],
    script: [PodcastScript, ->(c) {
      agent = ScriptAgent.new(guidelines: "g", script_path: File.join(Dir.tmpdir, "effort_wiring_script.md"))
      agent.instance_variable_set(:@client, c)
      agent.generate([{topic: "t", findings: [{title: "a", url: "https://example.com/a", summary: "s"}]}])
    }],
    reviewer: [ScriptReview, ->(c) {
      reviewer = ScriptReviewer.new(date: Date.new(2026, 10, 12), research_data: [])
      reviewer.instance_variable_set(:@client, c)
      reviewer.send(:run_ai_review, {title: "T", segments: [{name: "S", text: "Hello"}]})
    }],
    translation: [TranslatedScript, ->(c) {
      agent = TranslationAgent.new(target_language: "es")
      agent.instance_variable_set(:@client, c)
      agent.send(:claude_request, "system", "user")
    }],
    transcript_reconciler: [nil, ->(c) {
      merger = Transcription::TranscriptMerger.new
      merger.instance_variable_set(:@client, c)
      merger.cleanup("Some text.")
    }],
    subtitle_reconciler: [nil, ->(c) {
      Anthropic::Client.stub(:new, ->(**) { c }) do
        SubtitleReconciler.reconcile([{"start" => 0.0, "end" => 1.0, "text" => "hi"}], "hi", api_key: "k")
      end
    }],
    vocab: [nil, ->(c) {
      annotator = VocabularyAnnotator.new("k")
      annotator.instance_variable_set(:@client, c)
      annotator.send(:classify_single, "besedilo", "Slovenian", "B1")
    }],
    image_rank: [nil, ->(c) {
      ranker = ImageRanker.new
      ranker.instance_variable_set(:@client, c)
      ranker.rank([{path: __FILE__, ext: ".png"}], title: "T", description: "D")
    }],
    web_search: [nil, ->(c) {
      source = ClaudeWebSource.new
      source.instance_variable_set(:@client, c)
      source.send(:call_api, "topic")
    }],
    tell_translate: [nil, ->(c) {
      translator = Tell::ClaudeTranslator.new("k")
      translator.instance_variable_set(:@client, c)
      translator.translate("hola", from: "es", to: "en")
    }],
    gloss: [nil, ->(c) {
      glosser = Tell::Glosser.new("k")
      glosser.instance_variable_set(:@client, c)
      glosser.send(:ask, "prompt")
    }]
  }.freeze

  def test_sites_cover_every_role_that_calls_messages_create
    # language_detect and description are pinned in their own tests (P5-1).
    assert_equal (ClaudeModels::ROLES.keys - %i[description language_detect]).sort, SITES.keys.sort
  end

  SITES.each do |role, (format, drive)|
    define_method(:"test_#{role}_env_low_reaches_the_request") do
      ENV["CLAUDE_EFFORT_#{role.upcase}"] = "low"
      config = capture(drive)[:output_config]

      assert_equal :low, config&.dig(:effort), "role #{role}"
      assert_equal format, config[:format], "role #{role} keeps its structured format" if format
    end

    define_method(:"test_#{role}_env_unset_sends_no_effort") do
      config = capture(drive)[:output_config]

      refute config&.key?(:effort), "role #{role}"
      assert_equal format, config[:format], "role #{role} keeps its structured format" if format
      assert_nil config, "role #{role} sends no output_config" unless format
    end
  end

  def test_vocab_enrich_call_carries_effort_too
    ENV["CLAUDE_EFFORT_VOCAB"] = "low"
    config = capture(->(c) {
      annotator = VocabularyAnnotator.new("k")
      annotator.instance_variable_set(:@client, c)
      annotator.send(:call_enrich_api, [{lemma: "beseda"}], language: "Slovenian", target_language: "English", filters: {})
    })[:output_config]

    assert_equal({effort: :low}, config)
  end

  private

  def capture(drive)
    client = RecordingClient.new
    begin
      drive.call(client)
    rescue Captured
      nil # some callers (web_search) swallow errors themselves
    end
    assert_equal 1, client.calls.length
    client.calls.first
  end
end
