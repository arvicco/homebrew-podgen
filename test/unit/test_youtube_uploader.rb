# frozen_string_literal: true

require_relative "../test_helper"
require "youtube_uploader"
require "socket"
require "stringio"
require "tmpdir"
require "fileutils"

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

    mock_token_store = Minitest::Mock.new
    mock_token_store.expect(:delete, nil, ["default"])

    mock_authorizer = Minitest::Mock.new
    mock_authorizer.expect(:get_credentials, expired_cred, ["default"])

    # P1-16: consent is a collaborator; here it yields no code
    uploader = YouTubeUploader.new(consent: ->(_authorizer) { [nil, "http://127.0.0.1:1"] })
    Google::Auth::UserAuthorizer.stub(:new, mock_authorizer) do
      Google::Auth::Stores::FileTokenStore.stub(:new, mock_token_store) do
        assert_raises(RuntimeError, /No authorization code/) { uploader.authorize! }
      end
    end
    mock_token_store.verify
    mock_authorizer.verify
  ensure
    ENV["YOUTUBE_CLIENT_ID"] = original_id
    ENV["YOUTUBE_CLIENT_SECRET"] = original_secret
  end

  # --- P1-16: loopback consent replaces the discontinued OOB flow ---

  def test_authorize_exchanges_the_code_against_the_loopback_redirect
    original_id = ENV["YOUTUBE_CLIENT_ID"]
    original_secret = ENV["YOUTUBE_CLIENT_SECRET"]
    ENV["YOUTUBE_CLIENT_ID"] = "test-id"
    ENV["YOUTUBE_CLIENT_SECRET"] = "test-secret"

    exchanged = nil
    mock_authorizer = Object.new
    mock_authorizer.define_singleton_method(:get_credentials) { |_| nil }
    mock_authorizer.define_singleton_method(:get_and_store_credentials_from_code) do |**kw|
      exchanged = kw
      :creds
    end
    consent = ->(_authorizer) { ["code-abc", "http://127.0.0.1:4242"] }

    uploader = YouTubeUploader.new(consent: consent)
    Google::Auth::UserAuthorizer.stub(:new, mock_authorizer) do
      Google::Auth::Stores::FileTokenStore.stub(:new, Object.new) do
        uploader.authorize!
      end
    end

    assert_equal "code-abc", exchanged[:code]
    assert_equal "http://127.0.0.1:4242", exchanged[:base_url], "code must be exchanged against the SAME redirect it was issued for"
    assert_equal "default", exchanged[:user_id]
    refute defined?(YouTubeUploader::OOB_URI), "OOB flow is gone"
  ensure
    ENV["YOUTUBE_CLIENT_ID"] = original_id
    ENV["YOUTUBE_CLIENT_SECRET"] = original_secret
  end

  # --- Q-77 / I-9: no browser, no port, no wait without a terminal ---

  def test_loopback_consent_refuses_without_a_terminal_before_opening_a_port
    out = StringIO.new
    authorizer = Object.new
    authorizer.define_singleton_method(:get_authorization_url) { |base_url:| flunk "URL must not be built" }
    consent = YouTubeUploader::LoopbackConsent.new(io: out, open_browser: false, interactive: false)

    assert_raises(YouTubeUploader::NotInteractive) { consent.call(authorizer) }

    assert_nil consent.port, "no listener may be opened"
    assert_empty out.string, "nothing printed to a log nobody reads"
  end

  def test_loopback_consent_interactive_probe_needs_stdin_and_stderr_ttys
    consent = YouTubeUploader::LoopbackConsent.new(io: StringIO.new, open_browser: false)

    $stdin.stub(:tty?, false) do
      $stderr.stub(:tty?, true) { refute consent.interactive?, "launchd: no stdin tty" }
    end
    $stdin.stub(:tty?, true) do
      $stderr.stub(:tty?, false) { refute consent.interactive?, "stderr redirected to a log" }
      $stderr.stub(:tty?, true) { assert consent.interactive?, "a terminal session" }
    end
  end

  def test_authorize_raises_not_interactive_before_consent_when_no_terminal
    original_id = ENV["YOUTUBE_CLIENT_ID"]
    original_secret = ENV["YOUTUBE_CLIENT_SECRET"]
    ENV["YOUTUBE_CLIENT_ID"] = "test-id"
    ENV["YOUTUBE_CLIENT_SECRET"] = "test-secret"

    mock_authorizer = Minitest::Mock.new
    mock_authorizer.expect(:get_credentials, nil, ["default"])

    consent = Object.new
    consent.define_singleton_method(:interactive?) { false }
    consent.define_singleton_method(:call) { |_authorizer| flunk "consent must not run without a terminal" }
    token_file = File.join(Dir.mktmpdir("podgen_yt_token"), "youtube_token.json")
    File.write(token_file, "{}\n")
    uploader = YouTubeUploader.new(consent: consent, token_file: token_file)

    error = nil
    Google::Auth::UserAuthorizer.stub(:new, mock_authorizer) do
      Google::Auth::Stores::FileTokenStore.stub(:new, Object.new) do
        error = assert_raises(YouTubeUploader::NotInteractive) { uploader.authorize! }
      end
    end
    mock_authorizer.verify

    assert_includes error.message, "#{token_file}: 3 bytes, modified", "names the token file and its state"
    assert_match(/from a terminal/, error.message, "tells the owner where to authorize")
  ensure
    ENV["YOUTUBE_CLIENT_ID"] = original_id
    ENV["YOUTUBE_CLIENT_SECRET"] = original_secret
    FileUtils.rm_rf(File.dirname(token_file)) if token_file
  end

  def test_loopback_consent_serves_the_callback_and_returns_code_and_redirect
    out = StringIO.new
    authorizer = Object.new
    authorizer.define_singleton_method(:get_authorization_url) { |base_url:| "https://accounts.example/auth?redirect_uri=#{base_url}" }
    consent = YouTubeUploader::LoopbackConsent.new(io: out, open_browser: false, interactive: true)

    result = nil
    t = Thread.new { result = consent.call(authorizer) }
    sleep 0.05 until consent.port # listener is up
    sock = TCPSocket.new("127.0.0.1", consent.port)
    sock.write("GET /?state=x&code=4%2Fthe-code HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
    response = sock.read
    sock.close
    t.join(5)

    code, redirect = result
    assert_equal "4/the-code", code, "code is URL-decoded"
    assert_equal "http://127.0.0.1:#{consent.port}", redirect
    assert response.start_with?("HTTP/1.1 200"), "callback must answer 200"
    assert_includes response, "authorized"
    assert_includes out.string, "https://accounts.example/auth?redirect_uri=http://127.0.0.1:#{consent.port}"
  end

  def test_loopback_consent_skips_an_idle_preconnect_socket_and_takes_the_real_callback
    out = StringIO.new
    authorizer = Object.new
    authorizer.define_singleton_method(:get_authorization_url) { |base_url:| "https://x/#{base_url}" }
    consent = YouTubeUploader::LoopbackConsent.new(io: out, open_browser: false, interactive: true, idle_timeout: 0.2)

    result = nil
    t = Thread.new { result = consent.call(authorizer) }
    sleep 0.05 until consent.port
    idle = TCPSocket.new("127.0.0.1", consent.port) # browser pre-connect: opens, sends nothing
    sleep 0.3
    real = TCPSocket.new("127.0.0.1", consent.port)
    real.write("GET /?code=real-code HTTP/1.1\r\n\r\n")
    real.read
    real.close
    idle.close
    t.join(5)

    assert_equal "real-code", result.first
  end

  def test_loopback_consent_gives_up_after_the_overall_wait
    authorizer = Object.new
    authorizer.define_singleton_method(:get_authorization_url) { |base_url:| "https://x/#{base_url}" }
    consent = YouTubeUploader::LoopbackConsent.new(io: StringIO.new, open_browser: false, interactive: true, wait: 0.2)

    code, redirect = consent.call(authorizer)

    assert_nil code
    assert_match(/\Ahttp:\/\/127\.0\.0\.1:\d+\z/, redirect)
  end

  def test_loopback_consent_returns_nil_code_when_callback_has_no_code
    authorizer = Object.new
    authorizer.define_singleton_method(:get_authorization_url) { |base_url:| "https://x/#{base_url}" }
    consent = YouTubeUploader::LoopbackConsent.new(io: StringIO.new, open_browser: false, interactive: true)

    result = nil
    t = Thread.new { result = consent.call(authorizer) }
    sleep 0.05 until consent.port
    sock = TCPSocket.new("127.0.0.1", consent.port)
    sock.write("GET /?error=access_denied HTTP/1.1\r\n\r\n")
    sock.read
    sock.close
    t.join(5)

    assert_nil result.first
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
