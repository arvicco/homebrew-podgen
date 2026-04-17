# frozen_string_literal: true

require_relative "../test_helper"
require "subtitle_parser"

class TestSubtitleParser < Minitest::Test
  def test_parse_srt
    srt = <<~SRT
      1
      00:00:01,000 --> 00:00:03,000
      Hello world.

      2
      00:00:04,000 --> 00:00:06,000
      Second line.
    SRT
    assert_equal "Hello world. Second line.", SubtitleParser.parse_srt(srt)
  end

  def test_parse_srt_empty
    assert_equal "", SubtitleParser.parse_srt("")
  end

  def test_parse_vtt
    vtt = <<~VTT
      WEBVTT

      00:00:01.000 --> 00:00:03.000
      Hello world.

      00:00:04.000 --> 00:00:06.000
      Second line.
    VTT
    assert_equal "Hello world. Second line.", SubtitleParser.parse_vtt(vtt)
  end

  def test_parse_vtt_with_header_metadata
    vtt = <<~VTT
      WEBVTT
      Kind: captions
      Language: en

      00:00:01.000 --> 00:00:03.000
      Hello.
    VTT
    assert_equal "Hello.", SubtitleParser.parse_vtt(vtt)
  end

  def test_parse_json_array_format
    json = '[{"startTime": 0, "endTime": 3, "body": "Hello."}, {"startTime": 3, "endTime": 6, "body": "World."}]'
    assert_equal "Hello. World.", SubtitleParser.parse_json(json)
  end

  def test_parse_json_segments_format
    json = '{"segments": [{"text": "Hello."}, {"text": "World."}]}'
    assert_equal "Hello. World.", SubtitleParser.parse_json(json)
  end

  def test_parse_json_invalid
    assert_equal "", SubtitleParser.parse_json("not json")
  end

  def test_detect_format_srt
    srt = "1\n00:00:01,000 --> 00:00:03,000\nHello"
    assert_equal :srt, SubtitleParser.detect_format(srt)
  end

  def test_detect_format_vtt
    assert_equal :vtt, SubtitleParser.detect_format("WEBVTT\n\n00:00:01.000 --> 00:00:03.000\nHello")
  end

  def test_detect_format_json_array
    assert_equal :json, SubtitleParser.detect_format('[{"body": "hello"}]')
  end

  def test_detect_format_json_object
    assert_equal :json, SubtitleParser.detect_format('{"segments": []}')
  end

  def test_detect_format_plain_text
    assert_equal :text, SubtitleParser.detect_format("Just some plain text.")
  end

  def test_detect_format_from_content_type
    assert_equal :srt, SubtitleParser.detect_format("anything", "application/x-subrip")
    assert_equal :vtt, SubtitleParser.detect_format("anything", "text/vtt")
    assert_equal :json, SubtitleParser.detect_format("anything", "application/json")
  end

  def test_parse_auto_detects_format
    srt = "1\n00:00:01,000 --> 00:00:03,000\nHello world."
    assert_equal "Hello world.", SubtitleParser.parse(srt)
  end
end
