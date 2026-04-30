# frozen_string_literal: true

require_relative "../test_helper"
require "script_renderer"

class TestScriptRenderer < Minitest::Test
  # --- core rendering ---

  def test_basic_render_emits_title_and_segments
    out = ScriptRenderer.render(sample_script)
    assert_includes out, "# Test Episode"
    assert_includes out, "## Opening"
    assert_includes out, "Welcome to the show."
    assert_includes out, "## Topic"
  end

  def test_no_links_section_when_links_config_nil
    out = ScriptRenderer.render(sample_script, links_config: nil)
    refute_includes out, "## More info"
    refute_includes out, "example.com"
  end

  # --- bottom links ---

  def test_bottom_links_appended_after_segments
    script = sample_script.merge(sources: [{ title: "Example Article", url: "https://example.com/article?utm_source=t" }])
    out = ScriptRenderer.render(script, links_config: { show: true })

    assert_includes out, "## More info"
    assert_includes out, "[Example Article]"
    refute_includes out, "utm_source"
  end

  def test_bottom_links_custom_title
    script = sample_script.merge(sources: [{ title: "Source", url: "https://example.com" }])
    out = ScriptRenderer.render(script, links_config: { show: true, title: "Read more" })

    assert_includes out, "## Read more"
    refute_includes out, "## More info"
  end

  def test_bottom_links_respects_max
    script = sample_script.merge(sources: [
      { title: "Source 1", url: "https://example.com/1" },
      { title: "Source 2", url: "https://example.com/2" },
      { title: "Source 3", url: "https://example.com/3" }
    ])
    out = ScriptRenderer.render(script, links_config: { show: true, max: 2 })

    assert_includes out, "Source 1"
    assert_includes out, "Source 2"
    refute_includes out, "Source 3"
  end

  # --- inline links ---

  def test_inline_links_after_each_segment
    script = {
      title: "Episode",
      segments: [
        { name: "AI News", text: "GPT-5 launched.", sources: [{ title: "GPT-5", url: "https://example.com/gpt5" }] },
        { name: "Wrap-Up", text: "Thanks for listening." }
      ],
      sources: [{ title: "GPT-5", url: "https://example.com/gpt5" }]
    }

    out = ScriptRenderer.render(script, links_config: { show: true, position: "inline" })

    refute_includes out, "## More info"
    ai_pos = out.index("GPT-5 launched.")
    link_pos = out.index("[GPT-5]")
    wrapup_pos = out.index("## Wrap-Up")
    assert link_pos > ai_pos
    assert link_pos < wrapup_pos
  end

  def test_inline_links_skips_segments_without_sources
    script = {
      title: "Episode",
      segments: [
        { name: "Opening", text: "Welcome." },
        { name: "News", text: "Content.", sources: [{ title: "S1", url: "https://example.com" }] }
      ],
      sources: []
    }

    out = ScriptRenderer.render(script, links_config: { show: true, position: "inline" })
    assert_equal 1, out.scan(/\[S1\]/).length
  end

  def test_inline_links_respects_per_section_max
    script = {
      title: "Episode",
      segments: [{
        name: "News", text: "Content.",
        sources: [
          { title: "S1", url: "https://example.com/1" },
          { title: "S2", url: "https://example.com/2" },
          { title: "S3", url: "https://example.com/3" }
        ]
      }],
      sources: []
    }

    out = ScriptRenderer.render(script, links_config: { show: true, position: "inline", max: 1 })
    assert_includes out, "S1"
    refute_includes out, "S2"
  end

  # --- url cleaning ---

  def test_render_strips_tracking_params_from_urls
    script = sample_script.merge(sources: [
      { title: "Article A", url: "https://example.com/a?utm_source=test" }
    ])
    out = ScriptRenderer.render(script, links_config: { show: true })

    assert_includes out, "(https://example.com/a)"
    refute_includes out, "utm_source"
  end

  private

  def sample_script
    {
      title: "Test Episode",
      segments: [
        { name: "Opening", text: "Welcome to the show." },
        { name: "Topic", text: "Today we discuss things." }
      ],
      sources: []
    }
  end
end
