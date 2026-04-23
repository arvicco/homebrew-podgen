# frozen_string_literal: true

require "fileutils"

# Parses and writes the standard transcript/script markdown format:
#
#   # Title
#
#   Description (optional)
#
#   ## Transcript
#
#   Body text...
#
#   ## Vocabulary
#
#   - **word** /ipa/ (pos) — definition
#
class TranscriptParser
  Result = Struct.new(:title, :description, :header, :body, :vocabulary, :transcript_section, keyword_init: true)

  # Parse a transcript file or string into its structural components.
  def self.parse(path_or_text)
    text = file?(path_or_text) ? File.read(path_or_text) : path_or_text

    has_transcript = text.include?("## Transcript")

    if has_transcript
      parts = text.split("## Transcript", 2)
      header = parts.first
      raw_body = parts.last

      title, description = parse_header(header)
      body, vocabulary = split_vocabulary(raw_body)
    else
      # Script format: no ## Transcript heading
      lines = text.lines
      raw_title = lines.first&.strip&.sub(/^#\s+/, "")
      title = raw_title && !raw_title.empty? ? raw_title : "Untitled"
      body = lines[1..].to_a.join.strip
      description = nil
      header = lines.first.to_s
      vocabulary = nil
    end

    Result.new(title: title, description: description, header: header, body: body,
               vocabulary: vocabulary, transcript_section: has_transcript)
  end

  # Extract just the title (efficient — reads only first line for files).
  def self.extract_title(path_or_text)
    if file?(path_or_text)
      first_line = File.foreach(path_or_text).first
    else
      first_line = path_or_text.lines.first
    end
    first_line&.strip&.sub(/^#\s+/, "")
  end

  # Check if file/text contains a vocabulary section.
  def self.has_vocabulary?(path_or_text)
    if file?(path_or_text)
      File.foreach(path_or_text).any? { |line| line.include?("## Vocabulary") }
    else
      path_or_text.include?("## Vocabulary")
    end
  end

  # Write a transcript file in the standard format.
  def self.write(path, title:, description: nil, body:, vocabulary: nil)
    FileUtils.mkdir_p(File.dirname(path))

    content = "# #{title}\n\n"
    content += "#{description}\n\n" if description && !description.empty?
    content += "## Transcript\n\n"
    content += body.strip
    content += "\n\n## Vocabulary\n\n#{vocabulary.strip}" if vocabulary && !vocabulary.strip.empty?
    content += "\n"

    File.write(path, content)
  end

  def self.file?(path_or_text)
    path_or_text.is_a?(String) && !path_or_text.include?("\n") && File.exist?(path_or_text)
  end
  private_class_method :file?

  def self.parse_header(header)
    lines = header.lines
    raw_title = lines.first&.strip&.sub(/^#\s+/, "")
    title = raw_title && !raw_title.empty? ? raw_title : "Untitled"
    desc_lines = lines[1..].to_a.map(&:strip).reject(&:empty?)
    description = desc_lines.empty? ? nil : desc_lines.join("\n")
    [title, description]
  end
  private_class_method :parse_header

  def self.split_vocabulary(raw_body)
    if raw_body.include?("## Vocabulary")
      parts = raw_body.split("## Vocabulary", 2)
      [parts.first.strip, parts.last]
    else
      [raw_body.strip, nil]
    end
  end
  private_class_method :split_vocabulary
end
