# frozen_string_literal: true

require_relative "../test_helper"
require "word_stats"

class TestWordStats < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_word_stats_test")
    @episodes_dir = File.join(@tmpdir, "episodes")
    FileUtils.mkdir_p(@episodes_dir)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_returns_empty_when_no_transcripts
    stats = WordStats.new(config: stub_config).build
    assert_equal [], stats
  end

  def test_returns_empty_when_no_vocabulary
    write_transcript("ep1", body: "Some text without a vocab section.", vocabulary: nil)
    stats = WordStats.new(config: stub_config).build
    assert_equal [], stats
  end

  def test_aggregates_lemma_across_episodes
    write_transcript("ep1",
      body: "La principessa amava il principe.\nIl principe rideva.",
      vocabulary: <<~MD)
        - **principe** (B1 n.) — prince
      MD

    write_transcript("ep2",
      body: "Un altro principe arriva al castello.",
      vocabulary: <<~MD)
        - **principe** (B1 n.) — prince
        - **castello** (A2 n.) — castle
      MD

    stats = WordStats.new(config: stub_config).build
    by_lemma = stats.each_with_object({}) { |s, h| h[s.lemma] = s }

    assert_equal 2, by_lemma["principe"].vocab_count
    assert_equal 1, by_lemma["castello"].vocab_count
    # "principe" alone matches 3 times (NOT inside "principessa")
    assert_equal 3, by_lemma["principe"].body_count
    assert_equal 1, by_lemma["castello"].body_count
  end

  def test_picks_working_language_definition_for_multi_lang_entries
    # Latest episode has multi-language vocab. Old episode is unmarked
    # (single-language English in this case). Working language must be
    # detected as English so multi-lang entries also surface English defs.
    write_transcript("ep_old",
      body: "x.",
      vocabulary: <<~MD)
        - **kot** (B1 noun) — corner. A point or area where two lines meet.
      MD

    write_transcript("ep_new",
      body: "x.",
      vocabulary: <<~MD)
        (Russian, English)

        - **poleti** (B1 adv)
          - летом. В летнее время года.
          - in summer. During the summer season.
      MD

    # Stub Claude — return "English" since old def is ASCII Latin.
    fake_response = Struct.new(:content).new([Struct.new(:text).new("English")])
    fake_messages = Object.new
    fake_messages.define_singleton_method(:create) { |**_kw| fake_response }
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      stats = WordStats.new(config: stub_config(language: "sl")).build
      by_lemma = stats.each_with_object({}) { |s, h| h[s.lemma] = s }
      assert_match(/corner/, by_lemma["kot"].definition)
      assert_match(/in summer/, by_lemma["poleti"].definition)
    end
  end

  def test_caches_working_language_detection_to_disk
    write_transcript("ep_old", body: "x.",
      vocabulary: "- **kot** (B1 noun) — corner.\n")
    write_transcript("ep_new", body: "x.", vocabulary: <<~MD)
      (Russian, English)

      - **poleti** (B1 adv)
        - летом.
        - in summer.
    MD

    fake_response = Struct.new(:content).new([Struct.new(:text).new("English")])
    fake_messages = Object.new
    call_count = 0
    fake_messages.define_singleton_method(:create) do |**_kw|
      call_count += 1
      fake_response
    end
    fake_client = Struct.new(:messages).new(fake_messages)

    Anthropic::Client.stub(:new, fake_client) do
      WordStats.new(config: stub_config(language: "sl")).build
      assert_equal 1, call_count, "first run should call Claude once"

      WordStats.new(config: stub_config(language: "sl")).build
      assert_equal 1, call_count, "second run must use cached working_language"
    end
  end

  def test_rejects_original_forms_that_are_lone_lemma_particles
    # An LLM-generated vocab entry with a comma between word and reflexive
    # particle (e.g. "*ozrl, se*" when meant "*ozrl se*") would otherwise
    # add bare "se" to the forms set, matching every reflexive "se" in
    # the body. Reject single-word originals that are also one of the
    # multi-word lemma's own words.
    write_transcript("ep1",
      body: "Ozrl se nazaj. Pelje se domov. Vrača se k mami. Igra se zunaj.",
      vocabulary: <<~MD)
        - **ozreti se** (B2 verb) *ozrl, se* — to look back
      MD

    stats = WordStats.new(config: stub_config(language: "xx")).build
    s = stats.first
    refute_includes s.forms, "se", "particle 'se' must not leak into forms"
    # body has 4 occurrences of "se" but none should count for this lemma
    assert s.body_count <= 1, "expected ≤1 (only literal 'ozrl se' if present), got #{s.body_count}"
  end

  def test_uses_historical_original_surface_forms
    write_transcript("ep1",
      body: "Le principesse cantavano.",
      vocabulary: <<~MD)
        - **principessa** (B1 n.) *principesse* — princess
      MD

    stats = WordStats.new(config: stub_config).build
    by_lemma = stats.each_with_object({}) { |s, h| h[s.lemma] = s }

    # surface form "principesse" came from *original*; should be counted
    assert_equal 1, by_lemma["principessa"].body_count
    assert_includes by_lemma["principessa"].forms, "principesse"
  end

  def test_word_boundary_does_not_match_substrings
    write_transcript("ep1",
      body: "Le principesse erano nel principato del principio.",
      vocabulary: <<~MD)
        - **principe** (B1 n.) — prince
      MD

    stats = WordStats.new(config: stub_config).build
    s = stats.first
    # "principe" alone shouldn't match within "principesse", "principato", "principio"
    assert_equal 0, s.body_count
  end

  def test_caches_forms_to_disk
    write_transcript("ep1",
      body: "principe arriva.",
      vocabulary: "- **principe** (B1 n.) — prince\n")

    config = stub_config
    WordStats.new(config: config).build
    cache_path = File.join(File.dirname(config.episodes_dir), "word_forms.yml")
    assert File.exist?(cache_path)
    cache = YAML.safe_load(File.read(cache_path))
    assert_equal ["principe"], cache["forms"]["principe"]
  end

  def test_two_pass_top_matches_full_run
    # Build a small corpus where the top by base count is also the top by
    # expanded count (so two-pass and full agree). Sufficient to verify
    # the optimization branch produces consistent ordering for top-N.
    %w[a b c d e f g h i j].each do |basename|
      vocab = ""
      %w[alpha beta gamma delta].each do |w|
        vocab += "- **#{w}** (A1 noun) — #{w}\n"
      end
      body = "alpha alpha alpha beta beta gamma other words"
      write_transcript(basename, body: body, vocabulary: vocab)
    end

    full = WordStats.new(config: stub_config(language: "xx")).build
    File.delete(File.join(@tmpdir, "word_forms.yml")) if File.exist?(File.join(@tmpdir, "word_forms.yml"))
    two_pass = WordStats.new(config: stub_config(language: "xx")).build(top: 2)

    full_top2 = full.sort_by { |s| [-s.body_count, s.lemma] }.first(2).map(&:lemma)
    two_pass_top2 = two_pass.sort_by { |s| [-s.body_count, s.lemma] }.first(2).map(&:lemma)
    assert_equal full_top2, two_pass_top2
  end

  def test_skips_hunspell_for_multi_word_lemmas
    # Multi-word phrases would have hunspell expand individual tokens
    # (e.g. "andare" alone), producing false matches. Verify only the
    # lemma + originals end up in the form set.
    write_transcript("ep1",
      body: "Vado d'accordo con tutti. Andiamo via.",
      vocabulary: <<~MD)
        - **andare d'accordo** (B1 verb) — to get along
      MD

    stats = WordStats.new(config: stub_config(language: "it")).build
    forms = stats.first.forms
    refute_includes forms, "vado", "single-token expansion of 'andare' must not leak through"
    refute_includes forms, "andiamo"
    assert_includes forms, "andare d'accordo"
  end

  def test_cache_invalidates_on_lemma_set_change
    write_transcript("ep1", body: "x.", vocabulary: "- **alpha** (A1 n.) — first\n")
    config = stub_config
    WordStats.new(config: config).build

    # Add a new transcript with a different lemma
    write_transcript("ep2", body: "y.", vocabulary: "- **beta** (A1 n.) — second\n")
    stats = WordStats.new(config: config).build
    lemmas = stats.map(&:lemma).sort
    assert_equal ["alpha", "beta"], lemmas
  end

  private

  def stub_config(language: "it")
    Struct.new(:episodes_dir, :transcription_language, keyword_init: true).new(
      episodes_dir: @episodes_dir, transcription_language: language
    )
  end

  def write_transcript(basename, body:, vocabulary:)
    content = "# Title #{basename}\n\nDescription\n\n## Transcript\n\n#{body}\n"
    content += "\n## Vocabulary\n\n#{vocabulary}\n" if vocabulary
    File.write(File.join(@episodes_dir, "#{basename}_transcript.md"), content)
  end
end
