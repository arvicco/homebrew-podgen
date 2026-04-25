# frozen_string_literal: true

require "set"
require "yaml"
require "digest"
require_relative "transcript_parser"
require_relative "transcript_renderer"
require_relative "atomic_writer"
require_relative "tell/hunspell"

# Aggregates vocabulary-frequency stats across all transcripts of a podcast.
#
# For each lemma found in any episode's ## Vocabulary section:
#   vocab_count — number of episodes the lemma appears in (vocabulary section)
#   body_count  — number of times the lemma OR any of its inflected forms
#                 appears in the transcript bodies
#
# Inflected forms come from three sources:
#   1. The lemma itself (downcased)
#   2. Every historical *original* surface form recorded in past vocab entries
#   3. Tell::Hunspell.expand(lemma, lang:) when the language's dictionary is
#      installed; gracefully absent otherwise
#
# Forms are cached per podcast in output/<podcast>/word_forms.yml and
# regenerated only when the lemma set or hunspell-availability changes.
class WordStats
  include TranscriptRenderer

  CACHE_FILENAME = "word_forms.yml"

  Result = Struct.new(:lemma, :pos, :definition, :vocab_count, :body_count, :forms, keyword_init: true)

  def initialize(config:, logger: nil)
    @config = config
    @logger = logger
  end

  def build
    transcripts = collect_transcripts
    return [] if transcripts.empty?

    vocab_index = aggregate_vocab(transcripts)
    return [] if vocab_index.empty?

    forms_by_lemma = resolve_forms(vocab_index)
    body_text = transcripts.map { |t| t[:body].to_s }.join("\n").downcase

    vocab_index.map do |lemma, info|
      forms = forms_by_lemma[lemma] || [lemma]
      Result.new(
        lemma: lemma,
        pos: info[:pos],
        definition: info[:definition],
        vocab_count: info[:episode_count],
        body_count: count_occurrences(body_text, forms),
        forms: forms
      )
    end
  end

  private

  def collect_transcripts
    dir = @config.episodes_dir
    return [] unless Dir.exist?(dir)

    Dir.glob(File.join(dir, "*_transcript.md")).sort.map do |path|
      parsed = TranscriptParser.parse(path)
      vocab_entries = parsed.vocabulary ? parse_vocab_entries(parsed.vocabulary) : nil
      { basename: File.basename(path, "_transcript.md"),
        body: parsed.body,
        vocab_entries: vocab_entries || {} }
    end
  end

  # Returns a hash: lemma => { pos:, definition:, episode_count:, originals: [...] }
  def aggregate_vocab(transcripts)
    index = {}
    transcripts.each do |t|
      seen_in_episode = Set.new
      t[:vocab_entries].each_value do |entry|
        lemma = entry[:lemma].to_s.downcase.strip
        next if lemma.empty?
        seen_in_episode.add(lemma)

        slot = (index[lemma] ||= {
          pos: entry[:pos],
          definition: entry[:definition] || (entry[:definitions] && entry[:definitions].values.compact.first),
          episode_count: 0,
          originals: Set.new
        })

        if entry[:original]
          entry[:original].to_s.split(/,\s*/).each do |form|
            slot[:originals].add(form.downcase.strip) unless form.strip.empty?
          end
        end
      end
      seen_in_episode.each { |lemma| index[lemma][:episode_count] += 1 }
    end
    index
  end

  def resolve_forms(vocab_index)
    lemmas = vocab_index.keys.sort
    lang = language_code
    hunspell_ok = Tell::Hunspell.supports?(lang) if lang
    cache_hash = compute_cache_hash(lemmas, lang, hunspell_ok)

    cache = load_cache
    if cache && cache["hash"] == cache_hash
      return cache["forms"].each_with_object({}) { |(k, v), h| h[k] = v.uniq }
    end

    if lang.nil?
      log("Warning: no transcription_language configured; using lemma + originals only")
    elsif !hunspell_ok
      log("Warning: hunspell dict for '#{lang}' not installed; body_count uses lemma + " \
          "historical surface forms only.")
      log("  Install: clone github.com/wooorm/dictionaries → " \
          "copy <lang>/index.{dic,aff} to ~/Library/Spelling/<LANG_CODE>.{dic,aff}")
    end

    log("Generating word forms for #{lemmas.length} lemma(s)#{hunspell_ok ? " (hunspell)" : ''}")
    forms = {}
    lemmas.each do |lemma|
      set = Set.new
      set.add(lemma)
      vocab_index[lemma][:originals].each { |o| set.add(o) }
      # Hunspell expansion is only meaningful for single-word lemmas. For
      # multi-word phrases (e.g. "andare d'accordo"), hunspell falls back
      # to expanding individual tokens, which yields false matches across
      # the corpus. Skip those — surface forms cover them adequately.
      if hunspell_ok && lemma.match?(/\A\p{L}+\z/u)
        expanded = Tell::Hunspell.expand(lemma, lang: lang) || []
        expanded.each { |f| set.add(f.downcase) }
      end
      forms[lemma] = set.to_a
    end

    save_cache(hash: cache_hash, forms: forms, language: lang, hunspell: hunspell_ok)
    forms
  end

  def language_code
    @config.respond_to?(:transcription_language) ? @config.transcription_language : nil
  end

  def cache_path
    File.join(File.dirname(@config.episodes_dir), CACHE_FILENAME)
  end

  def load_cache
    return nil unless File.exist?(cache_path)
    YAML.safe_load(File.read(cache_path))
  rescue
    nil
  end

  def save_cache(hash:, forms:, language:, hunspell:)
    data = {
      "hash" => hash,
      "language" => language,
      "hunspell" => hunspell,
      "forms" => forms.transform_values(&:uniq)
    }
    AtomicWriter.write_yaml(cache_path, data)
  end

  def compute_cache_hash(lemmas, lang, hunspell_ok)
    Digest::SHA256.hexdigest([lemmas.sort.join("\x00"), lang, hunspell_ok].join("|"))
  end

  def count_occurrences(text, forms)
    forms.uniq.sum do |form|
      escaped = Regexp.escape(form)
      regex = /(?<![\p{L}\p{Nd}])#{escaped}(?![\p{L}\p{Nd}])/u
      text.scan(regex).length
    end
  end

  def log(msg)
    @logger&.log("[WordStats] #{msg}")
  end
end
