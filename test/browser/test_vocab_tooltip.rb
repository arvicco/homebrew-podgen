# frozen_string_literal: true

require_relative "../test_helper_browser"

class VocabTooltipTest < BrowserTest
  TRANSCRIPT_BODY = <<~HTML
    <p class="transcript">
      A sentence with
      <a href="#vocab-alpha" class="vocab-word">alpha<span class="vocab-tip"><strong>alpha</strong><span class="vocab-tip-def">first letter</span></span></a>
      and
      <a href="#vocab-beta" class="vocab-word">beta<span class="vocab-tip"><strong>beta</strong><span class="vocab-tip-def">second letter</span></span></a>
      in it.
    </p>
    <p id="outside" style="padding: 2rem;">Tap target outside any vocab word.</p>
    <section class="vocabulary">
      <h2>Vocabulary</h2>
      <dl>
        <dt id="vocab-alpha">alpha</dt><dd>first letter</dd>
        <dt id="vocab-beta">beta</dt><dd>second letter</dd>
      </dl>
    </section>
  HTML

  def setup
    @file = render_fixture(body: TRANSCRIPT_BODY, title: "Vocab Tooltip Test")
  end

  # --- touch input via CDP --------------------------------------------------
  # Dispatch real touch events through Chromium's input pipeline. This produces
  # trusted click events with pointerType === 'touch', the same way a finger
  # tap on a real mobile browser does. No mocks on window.matchMedia or
  # pointerType — we exercise the genuine code path.

  def tap_vocab(word)
    tap_at_selector(".vocab-word[href=\"#vocab-#{word}\"]")
  end

  def tap_at_selector(selector)
    coords = evaluate_script(<<~JS)
      (function() {
        var el = document.querySelector(#{selector.to_json});
        if (!el) return null;
        var r = el.getBoundingClientRect();
        return [r.left + r.width/2, r.top + r.height/2];
      })()
    JS
    raise "could not locate #{selector}" unless coords
    x, y = coords
    touch("touchStart", x, y)
    touch("touchEnd",   x, y)
  end

  def touch(type, x, y)
    points = (type == "touchEnd") ? [] : [{ x: x, y: y }]
    page.driver.browser.page.command("Input.dispatchTouchEvent", type: type, touchPoints: points)
  end

  # --- helpers --------------------------------------------------------------

  def visible_tooltip_count
    evaluate_script(<<~JS)
      Array.from(document.querySelectorAll('.vocab-tip')).filter(function(t) {
        return getComputedStyle(t).display !== 'none';
      }).length
    JS
  end

  def hash_fragment
    URI.parse(current_url).fragment
  end

  # --- desktop regression guards (real mouse click) ------------------------

  def test_desktop_hover_shows_exactly_one_tooltip
    visit "/#{@file}"
    find(".vocab-word", text: "alpha").hover
    assert_equal 1, visible_tooltip_count, "exactly one bubble should be visible on hover"
  end

  def test_desktop_mouse_click_navigates_to_vocab_anchor
    visit "/#{@file}"
    find(".vocab-word", text: "alpha").click
    assert_equal "vocab-alpha", hash_fragment
  end

  # --- mobile / touch behavior via real touch events -----------------------

  def test_touch_first_tap_shows_tooltip_without_navigation
    visit "/#{@file}"
    tap_vocab("alpha")
    assert_nil hash_fragment, "URL should not acquire anchor on first tap"
    assert has_selector?(".vocab-word.show-tip", text: "alpha"),
           "tapped word should have show-tip class"
  end

  def test_touch_second_tap_on_same_word_navigates
    visit "/#{@file}"
    tap_vocab("alpha")
    assert_nil hash_fragment, "first tap must not navigate"
    tap_vocab("alpha")
    assert_equal "vocab-alpha", hash_fragment
  end

  def test_touch_tap_outside_closes_tooltip
    visit "/#{@file}"
    tap_vocab("alpha")
    assert has_selector?(".vocab-word.show-tip", text: "alpha"),
           "show-tip must be set after first tap (precondition)"
    tap_at_selector("#outside")
    refute has_selector?(".vocab-word.show-tip"),
           "tapping outside should clear show-tip"
  end

  def test_touch_tap_on_different_word_switches_tooltip
    visit "/#{@file}"
    tap_vocab("alpha")
    tap_vocab("beta")
    assert has_selector?(".vocab-word.show-tip", text: "beta"),
           "second word should now have show-tip"
    refute has_selector?(".vocab-word.show-tip", text: "alpha"),
           "first word should no longer have show-tip"
  end
end
