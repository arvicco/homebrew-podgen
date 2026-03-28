# frozen_string_literal: true

require "google/apis/youtube_v3"
require "googleauth"
require "googleauth/stores/file_token_store"
require "fileutils"
require "json"

# Uploads videos and captions to YouTube via the Data API v3.
# Handles OAuth2 authentication with persistent token storage.
class YouTubeUploader
  OOB_URI = "urn:ietf:wg:oauth:2.0:oob"
  SCOPE = Google::Apis::YoutubeV3::AUTH_YOUTUBE_FORCE_SSL
  TOKEN_DIR = File.join(Dir.home, ".config", "podgen")
  TOKEN_FILE = File.join(TOKEN_DIR, "youtube_token.json")

  def initialize(logger: nil)
    @logger = logger
    @service = nil
  end

  # Authorize and return a configured YouTube service.
  # On first run, opens a browser for OAuth2 consent.
  def authorize!
    client_id = ENV["YOUTUBE_CLIENT_ID"]
    client_secret = ENV["YOUTUBE_CLIENT_SECRET"]
    raise "YOUTUBE_CLIENT_ID not set" unless client_id && !client_id.empty?
    raise "YOUTUBE_CLIENT_SECRET not set" unless client_secret && !client_secret.empty?

    FileUtils.mkdir_p(TOKEN_DIR)

    client_id_obj = Google::Auth::ClientId.new(client_id, client_secret)
    token_store = Google::Auth::Stores::FileTokenStore.new(file: TOKEN_FILE)
    authorizer = Google::Auth::UserAuthorizer.new(client_id_obj, SCOPE, token_store)

    credentials = authorizer.get_credentials("default")
    if credentials.nil?
      url = authorizer.get_authorization_url(base_url: OOB_URI)
      log("Open the following URL in your browser and authorize the application:")
      log(url)
      $stderr.print "\nEnter the authorization code: "
      code = $stdin.gets&.strip
      raise "No authorization code provided" if code.nil? || code.empty?
      credentials = authorizer.get_and_store_credentials_from_code(
        user_id: "default", code: code, base_url: OOB_URI
      )
    end

    @service = Google::Apis::YoutubeV3::YouTubeService.new
    @service.authorization = credentials
    log("YouTube API authorized")
    @service
  end

  # Upload a video to YouTube.
  # Returns the video_id.
  def upload_video(video_path, title:, description: "", language: "en",
                   privacy: "unlisted", category: "27", tags: [])
    ensure_authorized!

    metadata = Google::Apis::YoutubeV3::Video.new(
      snippet: Google::Apis::YoutubeV3::VideoSnippet.new(
        title: title,
        description: description,
        tags: tags,
        category_id: category,
        default_language: language,
        default_audio_language: language
      ),
      status: Google::Apis::YoutubeV3::VideoStatus.new(
        privacy_status: privacy,
        self_declared_made_for_kids: false
      )
    )

    log("Uploading video: #{title}")
    result = @service.insert_video(
      "snippet,status",
      metadata,
      upload_source: video_path,
      content_type: "video/mp4"
    )

    video_id = result.id
    log("Video uploaded: https://youtu.be/#{video_id}")
    video_id
  end

  # Upload captions (SRT) for a video.
  def upload_captions(video_id, srt_path, language:)
    ensure_authorized!

    caption = Google::Apis::YoutubeV3::Caption.new(
      snippet: Google::Apis::YoutubeV3::CaptionSnippet.new(
        video_id: video_id,
        language: language,
        name: ""
      )
    )

    log("Uploading captions for #{video_id} (#{language})")
    @service.insert_caption(
      "snippet",
      caption,
      upload_source: srt_path,
      content_type: "application/x-subrip"
    )
    log("Captions uploaded")
  end

  # Add a video to a playlist.
  def add_to_playlist(video_id, playlist_id)
    ensure_authorized!

    item = Google::Apis::YoutubeV3::PlaylistItem.new(
      snippet: Google::Apis::YoutubeV3::PlaylistItemSnippet.new(
        playlist_id: playlist_id,
        resource_id: Google::Apis::YoutubeV3::ResourceId.new(
          kind: "youtube#video",
          video_id: video_id
        )
      )
    )

    log("Adding #{video_id} to playlist #{playlist_id}")
    @service.insert_playlist_item("snippet", item)
    log("Added to playlist")
  end

  # Delete a video. Non-fatal on 404.
  def delete_video(video_id)
    ensure_authorized!

    log("Deleting video #{video_id}")
    @service.delete_video(video_id)
    log("Video deleted")
    true
  rescue Google::Apis::ClientError => e
    if e.status_code == 404
      log("Video #{video_id} already deleted (404)")
      false
    else
      raise
    end
  end

  private

  def ensure_authorized!
    authorize! unless @service
  end

  def log(msg)
    if @logger
      @logger.log("[YouTubeUploader] #{msg}")
    else
      $stderr.puts "[YouTubeUploader] #{msg}"
    end
  end
end
