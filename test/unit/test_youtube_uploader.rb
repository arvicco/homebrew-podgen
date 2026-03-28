# frozen_string_literal: true

require_relative "../test_helper"
require "youtube_uploader"

class TestYouTubeUploader < Minitest::Test
  def setup
    @uploader = YouTubeUploader.new
  end

  # --- authorize! ---

  def test_authorize_raises_without_client_id
    ENV.delete("YOUTUBE_CLIENT_ID")
    ENV.delete("YOUTUBE_CLIENT_SECRET")

    assert_raises(RuntimeError, /YOUTUBE_CLIENT_ID/) { @uploader.authorize! }
  end

  def test_authorize_raises_with_empty_client_id
    original_id = ENV["YOUTUBE_CLIENT_ID"]
    original_secret = ENV["YOUTUBE_CLIENT_SECRET"]
    ENV["YOUTUBE_CLIENT_ID"] = ""
    ENV["YOUTUBE_CLIENT_SECRET"] = "test"

    assert_raises(RuntimeError, /YOUTUBE_CLIENT_ID/) { @uploader.authorize! }
  ensure
    ENV["YOUTUBE_CLIENT_ID"] = original_id
    ENV["YOUTUBE_CLIENT_SECRET"] = original_secret
  end

  # --- upload_video metadata ---

  def test_upload_video_requires_authorization
    assert_raises(RuntimeError) { @uploader.upload_video("/tmp/test.mp4", title: "Test") }
  end

  # --- delete_video ---

  def test_delete_video_handles_404_gracefully
    mock_service = Minitest::Mock.new
    error = Google::Apis::ClientError.new("Not Found", status_code: 404)
    mock_service.expect(:delete_video, nil) { raise error }

    @uploader.instance_variable_set(:@service, mock_service)

    result = @uploader.delete_video("nonexistent")
    refute result, "Should return false for 404"
    mock_service.verify
  end

  def test_delete_video_reraises_non_404_errors
    mock_service = Minitest::Mock.new
    error = Google::Apis::ClientError.new("Forbidden", status_code: 403)
    mock_service.expect(:delete_video, nil) { raise error }

    @uploader.instance_variable_set(:@service, mock_service)

    assert_raises(Google::Apis::ClientError) { @uploader.delete_video("forbidden") }
    mock_service.verify
  end

  # --- constants ---

  def test_token_dir_is_under_home
    assert YouTubeUploader::TOKEN_DIR.start_with?(Dir.home)
  end

  def test_scope_is_youtube
    assert_includes YouTubeUploader::SCOPE.to_s, "youtube"
  end
end
