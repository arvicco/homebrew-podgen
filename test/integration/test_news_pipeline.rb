# frozen_string_literal: true

# Integration test: the offline part of the news pipeline chain.
# The live-source and real-API cases live in test/api/test_news_pipeline.rb.

require_relative "../test_helper"

class TestNewsPipeline < Minitest::Test
  def setup
    @tmpdir = Dir.mktmpdir("podgen_news_test")
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_script_with_sources_produces_links_section
    script = {
      title: "Test Episode",
      segments: [{ name: "Content", text: "A brief episode." }],
      sources: [
        { title: "Source One", url: "https://example.com/one?utm_source=test" },
        { title: "Source Two", url: "https://example.com/two" }
      ]
    }

    require "url_cleaner"

    path = File.join(@tmpdir, "episodes", "links_script.md")
    FileUtils.mkdir_p(File.dirname(path))
    # Replicate save_script_debug with links: true from generate_command.rb
    File.open(path, "w") do |f|
      f.puts "# #{script[:title]}"
      f.puts
      script[:segments].each do |seg|
        f.puts "## #{seg[:name]}"
        f.puts
        f.puts seg[:text]
        f.puts
      end
      if script[:sources] && !script[:sources].empty?
        f.puts "## More info"
        f.puts
        script[:sources].each do |src|
          clean_url = UrlCleaner.clean(src[:url])
          f.puts "- [#{src[:title]}](#{clean_url})"
        end
        f.puts
      end
    end

    content = File.read(path)
    assert_includes content, "## More info"
    assert_includes content, "[Source One]"
    assert_includes content, "[Source Two]"
    # UTM params should be stripped
    refute_includes content, "utm_source"
    assert_includes content, "https://example.com/one"
  end
end
