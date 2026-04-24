# frozen_string_literal: true

require_relative "test_helper"
require "capybara"
require "capybara/minitest"
require "capybara/cuprite"
require "erb"
require "rack/files"

TEMPLATES_DIR = File.expand_path("../lib/templates", __dir__)
FIXTURE_DIR = File.join(Dir.tmpdir, "podgen-browser-fixtures-#{Process.pid}")
FileUtils.mkdir_p(FIXTURE_DIR)
FileUtils.cp(File.join(TEMPLATES_DIR, "style.css"), File.join(FIXTURE_DIR, "style.css"))
Minitest.after_run { FileUtils.rm_rf(FIXTURE_DIR) }

Capybara.app = Rack::Files.new(FIXTURE_DIR)
Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(app, headless: true, window_size: [1200, 800], process_timeout: 15)
end
Capybara.default_driver = :cuprite
Capybara.javascript_driver = :cuprite
Capybara.default_max_wait_time = 2
Capybara.server = :puma, { Silent: true }

class BrowserTest < Minitest::Test
  include Capybara::DSL
  include Capybara::Minitest::Assertions

  def teardown
    Capybara.reset_sessions!
  end

  # Render the real layout.erb with a given body, write to FIXTURE_DIR, return the
  # served filename. Using the real template means tests exercise actual site HTML.
  def render_fixture(body:, filename: "page-#{object_id}.html", title: "Test Episode", site_config: {})
    layout_src = File.read(File.join(TEMPLATES_DIR, "layout.erb"))
    locals = {
      lang: "en",
      page_title: title,
      favicon_path: nil,
      css_path: "style.css",
      custom_css_path: nil,
      site_config: site_config,
      languages: [{ code: "en", name: "English", index_path: "/" }],
      content: body,
      footer_text: ""
    }
    rendered = ERB.new(layout_src, trim_mode: "-").result_with_hash(locals)
    File.write(File.join(FIXTURE_DIR, filename), rendered)
    filename
  end
end
