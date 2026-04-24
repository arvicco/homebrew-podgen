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

  # --- matchMedia emulation -------------------------------------------------
  # CDP's Emulation.setEmulatedMedia doesn't reliably flip window.matchMedia
  # under Cuprite/Ferrum, so we override the JS function directly. This tests
  # the code path that runs on real mobile browsers (where matchMedia returns
  # true for '(hover: none)').

  def set_mobile_mode
    override_match_media(hover: "none", pointer: "coarse")
  end

  def set_desktop_mode
    override_match_media(hover: "hover", pointer: "fine")
  end

  def override_match_media(hover:, pointer:)
    execute_script(<<~JS)
      (function() {
        var overrides = {
          '(hover: #{hover})': true,
          '(hover: none)': #{hover == "none"},
          '(pointer: #{pointer})': true,
          '(pointer: coarse)': #{pointer == "coarse"}
        };
        var original = window.__origMatchMedia || window.matchMedia;
        window.__origMatchMedia = original;
        window.matchMedia = function(q) {
          if (q in overrides) {
            return { matches: overrides[q], media: q,
                     addEventListener: function() {}, removeEventListener: function() {},
                     addListener: function() {}, removeListener: function() {} };
          }
          return original.call(window, q);
        };
      })();
    JS
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

  # --- desktop regression guards -------------------------------------------

  def test_desktop_hover_shows_exactly_one_tooltip
    visit "/#{@file}"
    set_desktop_mode
    find(".vocab-word", text: "alpha").hover
    assert_equal 1, visible_tooltip_count, "exactly one bubble should be visible on hover"
  end

  def test_desktop_click_navigates_to_vocab_anchor
    visit "/#{@file}"
    set_desktop_mode
    find(".vocab-word", text: "alpha").click
    assert_equal "vocab-alpha", hash_fragment
  end

  # --- mobile / touch behavior (failing until Phase 3) ---------------------

  def test_touch_first_tap_shows_tooltip_without_navigation
    visit "/#{@file}"
    set_mobile_mode
    find(".vocab-word", text: "alpha").click
    assert_nil hash_fragment, "URL should not acquire anchor on first tap"
    assert has_selector?(".vocab-word.show-tip", text: "alpha"),
           "tapped word should have show-tip class"
  end

  def test_touch_second_tap_on_same_word_navigates
    visit "/#{@file}"
    set_mobile_mode
    word = find(".vocab-word", text: "alpha")
    word.click
    assert_nil hash_fragment, "first tap must not navigate"
    word.click
    assert_equal "vocab-alpha", hash_fragment
  end

  def test_touch_tap_outside_closes_tooltip
    visit "/#{@file}"
    set_mobile_mode
    find(".vocab-word", text: "alpha").click
    assert has_selector?(".vocab-word.show-tip", text: "alpha"),
           "show-tip must be set after first tap (precondition)"
    find("#outside").click
    refute has_selector?(".vocab-word.show-tip"),
           "tapping outside should clear show-tip"
  end

  def test_touch_tap_on_different_word_switches_tooltip
    visit "/#{@file}"
    set_mobile_mode
    find(".vocab-word", text: "alpha").click
    find(".vocab-word", text: "beta").click
    assert has_selector?(".vocab-word.show-tip", text: "beta"),
           "second word should now have show-tip"
    refute has_selector?(".vocab-word.show-tip", text: "alpha"),
           "first word should no longer have show-tip"
  end
end
