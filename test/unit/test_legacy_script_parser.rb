# frozen_string_literal: true

require_relative "../test_helper"
require "legacy_script_parser"

class TestLegacyScriptParser < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_legacy")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_parse_extracts_title_and_segments
    path = write_md(<<~MD)
      # Episode Title

      ## Opening

      Welcome to the show.

      ## Wrap-Up

      Thanks for listening.
    MD

    result = LegacyScriptParser.parse(path)

    assert_equal "Episode Title", result[:title]
    assert_equal 2, result[:segments].length
    assert_equal "Opening", result[:segments][0][:name]
    assert_equal "Welcome to the show.", result[:segments][0][:text]
    assert_empty result[:sources]
  end

  def test_parse_recovers_inline_source_links
    path = write_md(<<~MD)
      # Mixed

      ## News

      Big story.

      - [Source 1](https://example.com/1)
      - [Source 2](https://example.com/2)

      ## Wrap-Up

      Thanks.
    MD

    result = LegacyScriptParser.parse(path)

    assert_equal 2, result[:segments].length
    seg = result[:segments][0]
    assert_equal "News", seg[:name]
    assert_equal "Big story.", seg[:text]
    assert_equal [
      { title: "Source 1", url: "https://example.com/1" },
      { title: "Source 2", url: "https://example.com/2" }
    ], seg[:sources]
    refute result[:segments][1].key?(:sources)
  end

  def test_parse_recovers_bottom_more_info_section
    path = write_md(<<~MD)
      # Episode

      ## Main

      Real content.

      ## More info

      - [Article 1](https://example.com/a)
      - [Article 2](https://example.com/b)
    MD

    result = LegacyScriptParser.parse(path)

    # Bottom link-only section becomes script-level :sources, not a fake segment.
    assert_equal 1, result[:segments].length
    assert_equal "Main", result[:segments][0][:name]
    refute result[:segments][0].key?(:sources)
    assert_equal [
      { title: "Article 1", url: "https://example.com/a" },
      { title: "Article 2", url: "https://example.com/b" }
    ], result[:sources]
  end

  def test_parse_aggregates_segment_sources_when_no_bottom_section
    path = write_md(<<~MD)
      # Inline only

      ## A

      Body.

      - [S1](https://example.com/1)

      ## B

      Body.

      - [S2](https://example.com/2)
      - [S1](https://example.com/1)
    MD

    result = LegacyScriptParser.parse(path)

    # Top-level :sources is the deduplicated union, in first-seen order.
    assert_equal [
      { title: "S1", url: "https://example.com/1" },
      { title: "S2", url: "https://example.com/2" }
    ], result[:sources]
  end

  def test_parse_preserves_speech_text_when_links_follow
    path = write_md(<<~MD)
      # Test

      ## News

      Multi-line body
      with two paragraphs.

      Second paragraph.

      - [Source](https://example.com)
    MD

    result = LegacyScriptParser.parse(path)
    assert_equal "Multi-line body\nwith two paragraphs.\n\nSecond paragraph.", result[:segments][0][:text]
    assert_equal 1, result[:segments][0][:sources].length
  end

  def test_split_body_and_links_handles_no_links
    body, links = LegacyScriptParser.split_body_and_links("Plain text only.")
    assert_equal "Plain text only.", body
    assert_empty links
  end

  def test_split_body_and_links_strips_only_link_bullets_not_other_bullets
    body, links = LegacyScriptParser.split_body_and_links("Body.\n\n- a regular bullet\n\n- [Link](https://example.com)")
    # Walk back: link bullet stripped, blank stripped — but next "- a regular bullet" is NOT a link bullet, so we stop.
    assert_equal "Body.\n\n- a regular bullet", body
    assert_equal 1, links.length
  end

  private

  def write_md(content)
    path = File.join(@tmpdir, "ep_script.md")
    File.write(path, content)
    path
  end
end
