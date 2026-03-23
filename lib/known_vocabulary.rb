# frozen_string_literal: true

require "yaml"
require "set"
require_relative "atomic_writer"

# Manages per-language known vocabulary words for a podcast.
# Words stored as downcased lemmas so all derivatives are automatically excluded.
# File format: YAML hash keyed by language code, values are sorted arrays of lemmas.
class KnownVocabulary
  def initialize(path)
    @path = path
  end

  def self.for_config(config)
    new(File.join(config.podcast_dir, "known_vocabulary.yml"))
  end

  # Returns sorted array of lemmas for a language.
  def lemmas(language)
    data = load
    data[language] || []
  end

  # Returns Set of downcased lemmas for filtering.
  def lemma_set(language)
    lemmas(language).to_set
  end

  # Add a lemma. Returns true if added, false if duplicate.
  def add(language, lemma)
    lemma = lemma.downcase
    data = load
    data[language] ||= []
    return false if data[language].include?(lemma)

    data[language] << lemma
    data[language].sort!
    save(data)
    true
  end

  # Remove a lemma. Returns true if removed, false if not found.
  def remove(language, lemma)
    lemma = lemma.downcase
    data = load
    return false unless data[language]&.include?(lemma)

    data[language].delete(lemma)
    data.delete(language) if data[language].empty?
    save(data)
    true
  end

  private

  def load
    return {} unless File.exist?(@path)

    data = YAML.load_file(@path)
    data.is_a?(Hash) ? data : {}
  rescue Psych::SyntaxError => e
    raise "YAML syntax error in #{@path}: #{e.message.sub(/\A\(.*?\):\s*/, '')}"
  end

  def save(data)
    if data.empty?
      AtomicWriter.delete_if_exists(@path)
    else
      AtomicWriter.write_yaml(@path, data)
    end
  end
end
