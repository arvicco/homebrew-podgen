# frozen_string_literal: true

require "json"
require_relative "atomic_writer"
require_relative "legacy_script_parser"

# Canonical structured persistence for podcast scripts.
# Markdown views (script.md, script.html) are derived; this JSON is the source of truth.
#
# Shape:
#   {
#     title: String,
#     segments: [{ name: String, text: String, sources: [{ title:, url: }]? }, ...],
#     sources: [{ title:, url: }]
#   }
module ScriptArtifact
  # Path next to the markdown view: <basename>_script.md → <basename>_script.json
  def self.json_path_for(markdown_path)
    markdown_path.sub(/\.md\z/, ".json")
  end

  def self.write(path, script)
    AtomicWriter.write(path, JSON.pretty_generate(serialize(script)))
  end

  def self.read(path)
    return nil unless File.exist?(path)
    data = JSON.parse(File.read(path), symbolize_names: true)
    return nil unless data.is_a?(Hash) && data[:title] && data[:segments].is_a?(Array)
    data
  rescue JSON::ParserError
    nil
  end

  def self.exist?(path)
    File.exist?(path)
  end

  # Read the canonical JSON artifact when present; otherwise fall back to
  # parsing the legacy markdown view. Returns the script hash, or nil if
  # neither file exists. Pass the markdown path; the JSON path is derived.
  #
  # Returns a tuple [script_hash, source] where source is :json | :legacy_md | nil.
  # The caller can use :legacy_md to log a deprecation/lossy notice.
  def self.read_with_fallback(md_path)
    json_path = json_path_for(md_path)
    if File.exist?(json_path)
      script = read(json_path)
      return [script, :json] if script
    end

    if File.exist?(md_path)
      return [LegacyScriptParser.parse(md_path), :legacy_md]
    end

    [nil, nil]
  end

  def self.serialize(script)
    {
      title: script[:title].to_s,
      segments: Array(script[:segments]).map { |s| serialize_segment(s) },
      sources: Array(script[:sources]).map { |src| serialize_source(src) }
    }
  end

  def self.serialize_segment(seg)
    out = { name: seg[:name].to_s, text: seg[:text].to_s }
    sources = Array(seg[:sources]).map { |s| serialize_source(s) }
    out[:sources] = sources unless sources.empty?
    out
  end

  def self.serialize_source(src)
    { title: src[:title].to_s, url: src[:url].to_s }
  end
end
