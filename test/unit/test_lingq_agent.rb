# frozen_string_literal: true

require_relative "../test_helper"

ENV["LINGQ_API_KEY"] ||= "test-key"
require "agents/lingq_agent"

class TestLingQAgent < Minitest::Test
  # --- Constants ---

  def test_base_url_constant
    assert_equal "https://www.lingq.com/api", LingQAgent::BASE_URL
  end

  def test_max_retries_constant
    assert_equal 3, LingQAgent::MAX_RETRIES
  end

  # --- Constructor ---

  def test_raises_without_api_key
    original = ENV.delete("LINGQ_API_KEY")
    err = assert_raises(RuntimeError) { LingQAgent.new }
    assert_includes err.message, "LINGQ_API_KEY"
  ensure
    ENV["LINGQ_API_KEY"] = original || "test-key"
  end

  def test_constructor_stores_api_key
    agent = LingQAgent.new
    assert_equal ENV["LINGQ_API_KEY"], agent.instance_variable_get(:@api_key)
  end

  # --- format_text ---

  def test_format_text_removes_blank_lines
    agent = LingQAgent.new
    result = agent.send(:format_text, "Hello\n\nWorld\n\n\nFoo")
    assert_equal "Hello\nWorld\nFoo", result
  end

  def test_format_text_preserves_non_empty_lines
    agent = LingQAgent.new
    result = agent.send(:format_text, "Line 1\nLine 2\nLine 3")
    assert_equal "Line 1\nLine 2\nLine 3", result
  end

  def test_format_text_handles_single_line
    agent = LingQAgent.new
    result = agent.send(:format_text, "Just one line")
    assert_equal "Just one line", result
  end

  def test_format_text_handles_all_blank_lines
    agent = LingQAgent.new
    result = agent.send(:format_text, "\n\n\n")
    assert_equal "", result
  end

  def test_format_text_strips_bold_markers
    agent = LingQAgent.new
    result = agent.send(:format_text, "Imela je **puščico**.")
    assert_equal "Imela je puščico.", result
  end

  def test_format_text_strips_bold_preserves_punctuation
    agent = LingQAgent.new
    result = agent.send(:format_text, "Na **robu** mesta. Imela je **dragocenosti**.")
    assert_equal "Na robu mesta. Imela je dragocenosti.", result
  end

  # --- upload body construction ---

  def test_upload_builds_correct_body_with_required_fields
    Dir.mktmpdir do |dir|
      audio_path = File.join(dir, "test.mp3")
      File.write(audio_path, "fake audio data")

      agent = LingQAgent.new
      posted_body = nil

      agent.define_singleton_method(:post_with_retry) do |_url, body|
        posted_body = body
        12345
      end
      agent.define_singleton_method(:generate_timestamps) { |_lang, _id| }

      agent.upload(
        title: "Test Lesson",
        text: "Hello world\n\nGoodbye",
        audio_path: audio_path,
        language: "sl"
      )

      assert_equal "Test Lesson", posted_body[:title]
      assert_equal "Hello world\nGoodbye", posted_body[:text]
      assert_equal "private", posted_body[:status]
      assert_instance_of File, posted_body[:audio]
      refute posted_body.key?(:collection)
      refute posted_body.key?(:level)
      refute posted_body.key?(:tags)
      refute posted_body.key?(:accent)
      refute posted_body.key?(:description)
      refute posted_body.key?(:original_url)
    end
  end

  def test_upload_includes_optional_fields
    Dir.mktmpdir do |dir|
      audio_path = File.join(dir, "test.mp3")
      File.write(audio_path, "fake audio data")

      image_path = File.join(dir, "cover.jpg")
      File.write(image_path, "fake image data")

      agent = LingQAgent.new
      posted_body = nil
      posted_url = nil

      agent.define_singleton_method(:post_with_retry) do |url, body|
        posted_url = url
        posted_body = body
        99
      end
      agent.define_singleton_method(:generate_timestamps) { |_lang, _id| }
      patched_tags = nil
      agent.define_singleton_method(:patch_tags) { |_lang, _id, tags| patched_tags = tags }

      agent.upload(
        title: "Lesson",
        text: "Text",
        audio_path: audio_path,
        language: "ja",
        collection: "col-123",
        level: 3,
        tags: ["podcast", "japanese"],
        image_path: image_path,
        accent: "tokyo",
        status: "shared",
        description: "A podcast episode",
        original_url: "https://example.com/ep1"
      )

      assert_equal "col-123", posted_body[:collection]
      assert_equal "3", posted_body[:level]
      assert_equal ["podcast", "japanese"], patched_tags
      assert_equal "tokyo", posted_body[:accent]
      assert_equal "shared", posted_body[:status]
      assert_equal "A podcast episode", posted_body[:description]
      assert_equal "https://example.com/ep1", posted_body[:originalUrl]
      assert_instance_of File, posted_body[:image]
      assert_includes posted_url, "/ja/lessons/"
    end
  end

  def test_upload_skips_image_when_file_missing
    Dir.mktmpdir do |dir|
      audio_path = File.join(dir, "test.mp3")
      File.write(audio_path, "fake audio data")

      agent = LingQAgent.new
      posted_body = nil

      agent.define_singleton_method(:post_with_retry) do |_url, body|
        posted_body = body
        1
      end
      agent.define_singleton_method(:generate_timestamps) { |_lang, _id| }

      agent.upload(
        title: "T",
        text: "Text",
        audio_path: audio_path,
        language: "en",
        image_path: "/nonexistent/cover.jpg"
      )

      refute posted_body.key?(:image)
    end
  end

  def test_upload_returns_lesson_id
    Dir.mktmpdir do |dir|
      audio_path = File.join(dir, "test.mp3")
      File.write(audio_path, "fake audio data")

      agent = LingQAgent.new
      agent.define_singleton_method(:post_with_retry) { |_url, _body| 42 }
      agent.define_singleton_method(:generate_timestamps) { |_lang, _id| }

      result = agent.upload(
        title: "T",
        text: "Text",
        audio_path: audio_path,
        language: "en"
      )

      assert_equal 42, result
    end
  end

  def test_upload_omits_nil_tags
    Dir.mktmpdir do |dir|
      audio_path = File.join(dir, "test.mp3")
      File.write(audio_path, "fake audio data")

      agent = LingQAgent.new
      posted_body = nil

      agent.define_singleton_method(:post_with_retry) do |_url, body|
        posted_body = body
        1
      end
      agent.define_singleton_method(:generate_timestamps) { |_lang, _id| }

      agent.upload(
        title: "T",
        text: "Text",
        audio_path: audio_path,
        language: "en",
        tags: nil
      )

      refute posted_body.key?(:tags)
    end
  end

  def test_upload_omits_empty_tags
    Dir.mktmpdir do |dir|
      audio_path = File.join(dir, "test.mp3")
      File.write(audio_path, "fake audio data")

      agent = LingQAgent.new
      posted_body = nil

      agent.define_singleton_method(:post_with_retry) do |_url, body|
        posted_body = body
        1
      end
      agent.define_singleton_method(:generate_timestamps) { |_lang, _id| }

      agent.upload(
        title: "T",
        text: "Text",
        audio_path: audio_path,
        language: "en",
        tags: []
      )

      refute posted_body.key?(:tags)
    end
  end
end
