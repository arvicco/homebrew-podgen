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

  def test_authorize_deletes_expired_token_and_reprompts
    original_id = ENV["YOUTUBE_CLIENT_ID"]
    original_secret = ENV["YOUTUBE_CLIENT_SECRET"]
    ENV["YOUTUBE_CLIENT_ID"] = "test-id"
    ENV["YOUTUBE_CLIENT_SECRET"] = "test-secret"

    expired_cred = Object.new
    expired_cred.define_singleton_method(:expired?) { true }
    expired_cred.define_singleton_method(:refresh!) { raise Signet::AuthorizationError.new("expired") }

    # Use a real temp file as token store so delete actually works
    tmpfile = Tempfile.new("yt_token")
    tmpfile.write(JSON.dump("default" => "fake-token"))
    tmpfile.close

    mock_token_store = Minitest::Mock.new
    mock_token_store.expect(:delete, nil, ["default"])

    mock_authorizer = Minitest::Mock.new
    mock_authorizer.expect(:get_credentials, expired_cred, ["default"])
    mock_authorizer.expect(:get_authorization_url, "https://example.com", base_url: String)

    uploader = YouTubeUploader.new
    Google::Auth::UserAuthorizer.stub(:new, mock_authorizer) do
      Google::Auth::Stores::FileTokenStore.stub(:new, mock_token_store) do
        $stdin.stub(:gets, nil) do
          assert_raises(RuntimeError, /No authorization code/) { uploader.authorize! }
        end
      end
    end
    mock_token_store.verify
    mock_authorizer.verify
  ensure
    tmpfile&.unlink
    ENV["YOUTUBE_CLIENT_ID"] = original_id
    ENV["YOUTUBE_CLIENT_SECRET"] = original_secret
  end

  # --- upload_video ---

  def test_upload_video_without_service_triggers_authorize
    original_id = ENV.delete("YOUTUBE_CLIENT_ID")
    original_secret = ENV.delete("YOUTUBE_CLIENT_SECRET")

    uploader = YouTubeUploader.new
    # ensure_authorized! calls authorize! which fails without env vars
    assert_raises(RuntimeError, /YOUTUBE_CLIENT_ID/) { uploader.upload_video("/tmp/test.mp4", title: "Test") }
  ensure
    ENV["YOUTUBE_CLIENT_ID"] = original_id if original_id
    ENV["YOUTUBE_CLIENT_SECRET"] = original_secret if original_secret
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

  def test_delete_video_handles_403_gracefully
    mock_service = Minitest::Mock.new
    error = Google::Apis::ClientError.new("Forbidden", status_code: 403)
    mock_service.expect(:delete_video, nil) { raise error }

    @uploader.instance_variable_set(:@service, mock_service)

    result = @uploader.delete_video("forbidden")
    refute result, "Should return false for 403"
    mock_service.verify
  end

  def test_delete_video_reraises_other_errors
    mock_service = Minitest::Mock.new
    error = Google::Apis::ClientError.new("Bad Request", status_code: 400)
    mock_service.expect(:delete_video, nil) { raise error }

    @uploader.instance_variable_set(:@service, mock_service)

    assert_raises(Google::Apis::ClientError) { @uploader.delete_video("bad") }
    mock_service.verify
  end

  # --- verify_playlist! ---

  def test_verify_playlist_succeeds_when_playlist_exists
    mock_service = Minitest::Mock.new
    snippet = Struct.new(:title).new("My Playlist")
    item = Struct.new(:id, :snippet).new("PLtest123", snippet)
    response = Struct.new(:items).new([item])
    mock_service.expect(:list_playlists, response, ["snippet"], id: "PLtest123", max_results: 1)

    @uploader.instance_variable_set(:@service, mock_service)
    @uploader.verify_playlist!("PLtest123") # should not raise
    mock_service.verify
  end

  def test_verify_playlist_raises_when_playlist_not_found
    mock_service = Minitest::Mock.new
    response = Struct.new(:items).new([])
    mock_service.expect(:list_playlists, response, ["snippet"], id: "PLbadid", max_results: 1)

    @uploader.instance_variable_set(:@service, mock_service)

    error = assert_raises(RuntimeError) { @uploader.verify_playlist!("PLbadid") }
    assert_includes error.message, "PLbadid"
    assert_includes error.message, "not found"
    mock_service.verify
  end

  def test_verify_playlist_raises_when_items_nil
    mock_service = Minitest::Mock.new
    response = Struct.new(:items).new(nil)
    mock_service.expect(:list_playlists, response, ["snippet"], id: "PLnone", max_results: 1)

    @uploader.instance_variable_set(:@service, mock_service)

    assert_raises(RuntimeError) { @uploader.verify_playlist!("PLnone") }
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
