# frozen_string_literal: true

require_relative "../test_helper"
require "transcript_parser"

class TestTranscriptParser < Minitest::Test
  FULL_TRANSCRIPT = <<~MD
    # Episode Title

    Episode description here.

    ## Transcript

    First paragraph of transcript.

    Second paragraph of transcript.

    ## Vocabulary

    - **word** /wɜːrd/ (B2 noun) — a unit of language
  MD

  NO_VOCAB_TRANSCRIPT = <<~MD
    # My Title

    A brief description.

    ## Transcript

    Some transcript text.
  MD

  NO_DESCRIPTION_TRANSCRIPT = <<~MD
    # Bare Title

    ## Transcript

    Just the body.
  MD

  SCRIPT_FORMAT = <<~MD
    # Script Title

    Script intro line.

    First content paragraph.

    Second content paragraph.
  MD

  MULTI_LINE_DESCRIPTION = <<~MD
    # Title

    First line of description.
    Second line of description.

    ## Transcript

    Body text.
  MD

  # --- parse ---

  def test_parse_full_transcript_returns_all_components
    result = TranscriptParser.parse(FULL_TRANSCRIPT)

    assert_equal "Episode Title", result.title
    assert_equal "Episode description here.", result.description
    assert_equal "First paragraph of transcript.\n\nSecond paragraph of transcript.", result.body
    assert_includes result.vocabulary, "**word**"
  end

  def test_parse_without_vocabulary
    result = TranscriptParser.parse(NO_VOCAB_TRANSCRIPT)

    assert_equal "My Title", result.title
    assert_equal "A brief description.", result.description
    assert_equal "Some transcript text.", result.body
    assert_nil result.vocabulary
  end

  def test_parse_without_description
    result = TranscriptParser.parse(NO_DESCRIPTION_TRANSCRIPT)

    assert_equal "Bare Title", result.title
    assert_nil result.description
    assert_equal "Just the body.", result.body
  end

  def test_parse_script_without_transcript_section
    result = TranscriptParser.parse(SCRIPT_FORMAT)

    assert_equal "Script Title", result.title
    assert_nil result.description
    assert_includes result.body, "Script intro line."
    assert_includes result.body, "First content paragraph."
    assert_includes result.body, "Second content paragraph."
    assert_nil result.vocabulary
  end

  def test_parse_multi_line_description
    result = TranscriptParser.parse(MULTI_LINE_DESCRIPTION)

    assert_equal "Title", result.title
    assert_equal "First line of description.\nSecond line of description.", result.description
    assert_equal "Body text.", result.body
  end

  def test_parse_preserves_header_for_reassembly
    result = TranscriptParser.parse(FULL_TRANSCRIPT)

    # header is the raw text before "## Transcript"
    assert_includes result.header, "# Episode Title"
    assert_includes result.header, "Episode description here."
    refute_includes result.header, "## Transcript"
  end

  def test_parse_from_file
    Dir.mktmpdir("tp_test") do |dir|
      path = File.join(dir, "test_transcript.md")
      File.write(path, FULL_TRANSCRIPT)

      result = TranscriptParser.parse(path)

      assert_equal "Episode Title", result.title
      assert_equal "First paragraph of transcript.\n\nSecond paragraph of transcript.", result.body
      assert_includes result.vocabulary, "**word**"
    end
  end

  def test_parse_untitled_returns_default
    result = TranscriptParser.parse("\n\n## Transcript\n\nBody.")

    assert_equal "Untitled", result.title
  end

  # --- extract_title ---

  def test_extract_title_from_string
    assert_equal "Episode Title", TranscriptParser.extract_title(FULL_TRANSCRIPT)
  end

  def test_extract_title_from_file
    Dir.mktmpdir("tp_test") do |dir|
      path = File.join(dir, "test_transcript.md")
      File.write(path, "# File Title\n\nBody.")

      assert_equal "File Title", TranscriptParser.extract_title(path)
    end
  end

  def test_extract_title_strips_heading_marker
    assert_equal "Hello World", TranscriptParser.extract_title("# Hello World\n\nBody.")
  end

  # --- has_vocabulary? ---

  def test_has_vocabulary_true
    assert TranscriptParser.has_vocabulary?(FULL_TRANSCRIPT)
  end

  def test_has_vocabulary_false
    refute TranscriptParser.has_vocabulary?(NO_VOCAB_TRANSCRIPT)
  end

  def test_has_vocabulary_from_file
    Dir.mktmpdir("tp_test") do |dir|
      path = File.join(dir, "test_transcript.md")
      File.write(path, FULL_TRANSCRIPT)

      assert TranscriptParser.has_vocabulary?(path)
    end
  end

  # --- write ---

  def test_write_full_transcript
    Dir.mktmpdir("tp_test") do |dir|
      path = File.join(dir, "out_transcript.md")
      TranscriptParser.write(path,
        title: "My Title",
        description: "My description.",
        body: "Paragraph one.\n\nParagraph two.",
        vocabulary: "\n- **word** (B2 noun) — definition\n")

      content = File.read(path)
      assert_includes content, "# My Title\n"
      assert_includes content, "My description.\n"
      assert_includes content, "## Transcript\n\nParagraph one.\n\nParagraph two."
      assert_includes content, "## Vocabulary\n"
      assert_includes content, "**word**"
    end
  end

  def test_write_without_description
    Dir.mktmpdir("tp_test") do |dir|
      path = File.join(dir, "out_transcript.md")
      TranscriptParser.write(path, title: "Title", body: "Body text.")

      content = File.read(path)
      assert_includes content, "# Title\n\n## Transcript"
      refute_includes content, "\n\n\n"
    end
  end

  def test_write_without_vocabulary
    Dir.mktmpdir("tp_test") do |dir|
      path = File.join(dir, "out_transcript.md")
      TranscriptParser.write(path, title: "Title", description: "Desc.", body: "Body.")

      content = File.read(path)
      refute_includes content, "## Vocabulary"
    end
  end

  def test_write_creates_parent_directories
    Dir.mktmpdir("tp_test") do |dir|
      path = File.join(dir, "sub", "dir", "out_transcript.md")
      TranscriptParser.write(path, title: "T", body: "B.")

      assert File.exist?(path)
    end
  end

  # --- roundtrip ---

  def test_parse_then_write_roundtrips
    Dir.mktmpdir("tp_test") do |dir|
      parsed = TranscriptParser.parse(FULL_TRANSCRIPT)

      path = File.join(dir, "roundtrip_transcript.md")
      TranscriptParser.write(path,
        title: parsed.title,
        description: parsed.description,
        body: parsed.body,
        vocabulary: parsed.vocabulary)

      reparsed = TranscriptParser.parse(path)
      assert_equal parsed.title, reparsed.title
      assert_equal parsed.description, reparsed.description
      assert_equal parsed.body, reparsed.body
      assert_includes reparsed.vocabulary, "**word**"
    end
  end
end
