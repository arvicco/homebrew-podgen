# frozen_string_literal: true

require "yaml"

# Safe YAML file loading with consistent error handling.
# Counterpart to AtomicWriter.write_yaml for reading.
module YamlLoader
  # Load YAML file, returning +default+ if:
  # - file does not exist
  # - YAML parses to nil
  # - parsed data type doesn't match default's type (when default is non-nil)
  # - Psych::SyntaxError occurs (unless raise_on_error is true)
  def self.load(path, default: nil, raise_on_error: false)
    return default unless File.exist?(path)

    data = YAML.load_file(path)
    return default if data.nil?
    return data if default.nil?
    data.is_a?(default.class) ? data : default
  rescue Psych::SyntaxError => e
    raise "YAML syntax error in #{path}: #{e.message.sub(/\A\(.*?\):\s*/, '')}" if raise_on_error
    default
  end
end
