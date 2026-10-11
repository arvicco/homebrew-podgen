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

  # Paths and text are separate entry points: the *text* methods never touch
  # the filesystem, so a body that happens to equal an existing path is still
  # parsed as text (Q-10).

  # Parse a transcript file into its structural components.
  def self.parse_file(path)
    parse(File.read(path))
  end

  # Parse transcript text into its structural components.
  def self.parse(text)
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

  # Extract just the title from a file (efficient — reads only the first line).
  def self.extract_title_from_file(path)
    title_from_line(File.foreach(path).first)
  end

  # Extract just the title from transcript text.
  def self.extract_title(text)
    title_from_line(text.lines.first)
  end

  # Check if a transcript file contains a vocabulary section.
  def self.file_has_vocabulary?(path)
    File.foreach(path).any? { |line| line.include?("## Vocabulary") }
  end

  # Check if transcript text contains a vocabulary section.
  def self.has_vocabulary?(text)
    text.include?("## Vocabulary")
  end

  # Write a transcript file in the standard format.
  def self.write(path, title:, description: nil, body:, vocabulary: nil)
    FileUtils.mkdir_p(File.dirname(path))

    content = "# #{title}\n\n"
    content += "#{description}\n\n" if description && !description.empty?
    content += "## Transcript\n\n"
    content += body.strip
    if vocabulary && !vocabulary.strip.empty?
      v = vocabulary.strip
      content += if v.start_with?("## Vocabulary")
        "\n\n#{v}"
      else
        "\n\n## Vocabulary\n\n#{v}"
      end
    end
    content += "\n"

    File.write(path, content)
  end

  def self.title_from_line(first_line)
    first_line&.strip&.sub(/^#\s+/, "")
  end
  private_class_method :title_from_line

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
