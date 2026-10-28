# frozen_string_literal: true

require_relative "atomic_writer"
require_relative "yaml_loader"

# Per-show enrichment cache (output/<pod>/vocab_cache.yml): lemma →
# translations/definitions per target language, IPA, similar-language
# translations and the basename of the episode that first paid for it.
# Derived and regenerable (not a frozen schema); written atomically, once
# per annotate. Keys are downcased lemmas.
#
#   { "<lemma>" => { "translations" => { Lang => str }, "definitions" => { Lang => str },
#                    "pronunciation" => str|nil, "similar_translations" => { Lang => str }|nil,
#                    "first_seen" => "<basename>"|nil } }
class VocabCache
  attr_reader :path

  def initialize(path)
    @path = path
    @data = YamlLoader.load(path, default: {})
    @dirty = false
  end

  # The cached hash for lemma (string keys), or nil.
  def fetch(lemma)
    @data[key(lemma)]
  end

  # Merges the given languages into the lemma's entry; first_seen and the
  # language-independent fields are kept once set.
  def store(lemma, translations: {}, definitions: {}, pronunciation: nil, similar_translations: nil, first_seen: nil)
    entry = slot(lemma)
    entry["translations"].merge!(stringify(translations))
    entry["definitions"].merge!(stringify(definitions))
    entry["pronunciation"] ||= pronunciation
    entry["similar_translations"] ||= similar_translations && stringify(similar_translations)
    entry["first_seen"] ||= first_seen
    @dirty = true
    entry
  end

  # Overwrites one language's translation (and definition, when given).
  def set(lemma, lang, translation:, definition: nil)
    entry = slot(lemma)
    entry["translations"][lang.to_s] = translation
    entry["definitions"][lang.to_s] = definition if definition
    @dirty = true
    entry
  end

  def save
    return unless @dirty

    AtomicWriter.write_yaml(@path, @data)
    @dirty = false
  end

  def lemmas
    @data.keys
  end

  def size
    @data.size
  end

  private

  def key(lemma)
    lemma.to_s.downcase.strip
  end

  def slot(lemma)
    @data[key(lemma)] ||= {
      "translations" => {}, "definitions" => {}, "pronunciation" => nil,
      "similar_translations" => nil, "first_seen" => nil
    }
  end

  def stringify(hash)
    hash.to_h.transform_keys(&:to_s)
  end
end
