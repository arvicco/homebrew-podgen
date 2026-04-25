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

  # --- viewport overflow guards (mobile and desktop) -----------------------

  EDGE_BODY = <<~HTML
    <a href="#vocab-alpha" class="vocab-word" style="position:absolute; left: 10px; top: 200px;">alpha<span class="vocab-tip"><strong>alpha</strong><span class="vocab-tip-def">first letter, with a definition long enough to make the bubble wide</span></span></a>
    <a href="#vocab-beta" class="vocab-word" style="position:absolute; right: 10px; top: 200px;">beta<span class="vocab-tip"><strong>beta</strong><span class="vocab-tip-def">second letter, with a definition long enough to make the bubble wide</span></span></a>
    <section class="vocabulary">
      <dl><dt id="vocab-alpha">alpha</dt><dt id="vocab-beta">beta</dt></dl>
    </section>
  HTML

  def with_narrow_viewport(width: 400, height: 700)
    Capybara.current_session.current_window.resize_to(width, height)
    yield
  ensure
    Capybara.current_session.current_window.resize_to(1200, 800)
  end

  def tooltip_rect(word)
    evaluate_script(<<~JS)
      (function() {
        var el = document.querySelector('.vocab-word[href="#vocab-#{word}"] .vocab-tip');
        var r = el.getBoundingClientRect();
        return { left: r.left, right: r.right, width: r.width };
      })()
    JS
  end

  def test_touch_tooltip_stays_within_viewport_at_left_edge
    file = render_fixture(body: EDGE_BODY, title: "Edge")
    with_narrow_viewport do
      visit "/#{file}"
      tap_vocab("alpha")
      assert has_selector?(".vocab-word.show-tip"), "tooltip should be visible"
      rect = tooltip_rect("alpha")
      assert rect["left"] >= 0,
             "tooltip overflows left edge: left=#{rect['left']}"
      assert rect["right"] <= 400,
             "tooltip overflows right edge: right=#{rect['right']} viewport=400"
    end
  end

  def test_touch_tooltip_stays_within_viewport_at_right_edge
    file = render_fixture(body: EDGE_BODY, title: "Edge")
    with_narrow_viewport do
      visit "/#{file}"
      tap_vocab("beta")
      assert has_selector?(".vocab-word.show-tip"), "tooltip should be visible"
      rect = tooltip_rect("beta")
      assert rect["left"] >= 0,
             "tooltip overflows left edge: left=#{rect['left']}"
      assert rect["right"] <= 400,
             "tooltip overflows right edge: right=#{rect['right']} viewport=400"
    end
  end

  def test_desktop_hover_tooltip_stays_within_viewport_at_edge
    file = render_fixture(body: EDGE_BODY, title: "Edge")
    with_narrow_viewport do
      visit "/#{file}"
      find(".vocab-word", text: "alpha").hover
      rect = tooltip_rect("alpha")
      assert rect["left"] >= 0,
             "tooltip overflows left edge on hover: left=#{rect['left']}"
      assert rect["right"] <= 400,
             "tooltip overflows right edge on hover: right=#{rect['right']} viewport=400"
    end
  end
end
