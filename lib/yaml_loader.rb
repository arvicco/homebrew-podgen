# frozen_string_literal: true

require "yaml"

# Safe YAML file loading with consistent error handling.
# Counterpart to AtomicWriter.write_yaml for reading.
module YamlLoader
  # Load YAML file, returning +default+ if:
  # - file does not exist
  # - YAML parses to nil (raises instead when raise_on_error is true and
  #   empty: :raise — the ledger readers of history.yml and uploads.yml, for
  #   which an existing file that is empty or a bare `---` is a lost file a
  #   strict reader would otherwise rewrite as a fresh one)
  # - parsed data type doesn't match default's type (when default is non-nil;
  #   raises instead when raise_on_error is true — corruption, not emptiness)
  # - Psych::SyntaxError occurs (unless raise_on_error is true)
  def self.load(path, default: nil, raise_on_error: false, empty: :default)
    return default unless File.exist?(path)

    data = YAML.load_file(path)
    if data.nil?
      raise "#{path} exists but is empty — restore it from a backup; it is not read as an empty file" if raise_on_error && empty == :raise
      return default
    end
    return data if default.nil? || data.is_a?(default.class)
    raise "YAML in #{path}: expected #{default.class}, got #{data.class}" if raise_on_error
    default
  rescue Psych::SyntaxError => e
    raise "YAML syntax error in #{path}: #{e.message.sub(/\A\(.*?\):\s*/, '')}" if raise_on_error
    default
  end
end
