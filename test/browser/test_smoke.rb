# frozen_string_literal: true

require_relative "../test_helper_browser"

class BrowserSmokeTest < BrowserTest
  def test_fixture_renders_title_and_body
    body = %(<h1>Hello</h1><p>Vocab word: <a href="#vocab-beseda" class="vocab-word">beseda<span class="vocab-tip"><strong>beseda</strong><span class="vocab-tip-def">word</span></span></a></p>)
    file = render_fixture(body: body, title: "Smoke Episode")

    visit "/#{file}"

    assert_title "Smoke Episode"
    assert_selector ".vocab-word", text: "beseda"
  end
end
