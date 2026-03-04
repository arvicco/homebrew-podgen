# frozen_string_literal: true

require_relative "../test_helper"
require "agents/cover_agent"

class TestCoverAgent < Minitest::Test
  # Test the pure-logic methods without requiring ImageMagick/rsvg-convert

  # --- wrap_text ---

  def test_wrap_text_single_line
    lines = agent_class.allocate.send(:wrap_text, "SHORT", 980, 126)
    assert_equal 1, lines.length
    assert_equal "SHORT", lines.first
  end

  def test_wrap_text_wraps_long_text
    lines = agent_class.allocate.send(:wrap_text, "THIS IS A MUCH LONGER TITLE THAT SHOULD WRAP", 980, 126)
    assert lines.length > 1, "Should wrap into multiple lines"
    # All words should be present
    assert_equal "THIS IS A MUCH LONGER TITLE THAT SHOULD WRAP", lines.join(" ")
  end

  def test_wrap_text_respects_font_size
    # Larger font = fewer chars per line = more wrapping
    small = agent_class.allocate.send(:wrap_text, "ONE TWO THREE FOUR FIVE SIX", 980, 60)
    large = agent_class.allocate.send(:wrap_text, "ONE TWO THREE FOUR FIVE SIX", 980, 180)
    assert large.length >= small.length, "Larger font should produce more lines"
  end

  def test_wrap_text_minimum_chars_per_line
    # Even with enormous font, should have at least 4 chars per line
    lines = agent_class.allocate.send(:wrap_text, "ABCDEF", 100, 500)
    assert lines.length >= 1
  end

  # --- build_svg ---

  def test_build_svg_produces_valid_svg
    agent = agent_class.allocate
    svg = agent.send(:build_svg, ["HELLO", "WORLD"], CoverAgent::DEFAULTS)

    assert_includes svg, "<svg"
    assert_includes svg, "xmlns="
    assert_includes svg, "<tspan"
    assert_includes svg, "HELLO"
    assert_includes svg, "WORLD"
    assert_includes svg, CoverAgent::DEFAULTS[:font]
    assert_includes svg, CoverAgent::DEFAULTS[:font_color]
  end

  def test_build_svg_escapes_xml_entities
    agent = agent_class.allocate
    svg = agent.send(:build_svg, ["TOM & JERRY", "A < B > C"], CoverAgent::DEFAULTS)

    assert_includes svg, "TOM &amp; JERRY"
    assert_includes svg, "A &lt; B &gt; C"
    refute_includes svg, "TOM & JERRY"
  end

  def test_build_svg_first_line_uses_y_rest_use_dy
    agent = agent_class.allocate
    svg = agent.send(:build_svg, ["LINE1", "LINE2", "LINE3"], CoverAgent::DEFAULTS)

    # First tspan uses y=, rest use dy=
    assert_match(/tspan.*y="\d+".*LINE1/, svg)
    assert_match(/tspan.*dy="\d+".*LINE2/, svg)
    assert_match(/tspan.*dy="\d+".*LINE3/, svg)
  end

  # --- DEFAULTS ---

  def test_defaults_frozen
    assert CoverAgent::DEFAULTS.frozen?
  end

  def test_defaults_has_required_keys
    %i[font font_color font_size text_width text_height gravity x_offset y_offset].each do |key|
      assert CoverAgent::DEFAULTS.key?(key), "Missing default: #{key}"
    end
  end

  private

  def agent_class
    CoverAgent
  end
end
