# frozen_string_literal: true

require_relative "cover_resolver"
require_relative "auto_cover_resolver"

# Resolves the cover image for a language-pipeline episode.
#
# Priority chain:
# 1.  --image PATH/last/thumb (CLI flag)
# 2.  Per-feed image: PATH/last/thumb/none
# 2a. Per-feed image: auto → AutoCoverResolver; falls through if no winner
# 3.  --base-image PATH → title overlay
# 4.  Per-feed base_image: PATH → title overlay
# 5.  RSS episode image → downloaded from feed
# 6.  ## Image base_image → title overlay
# 7.  YouTube thumbnail → fallback
# 8.  nil → no cover
#
# Generated/temporary files accumulate in #temp_files and non-fatal
# problems in #warnings — the caller merges both after resolving.
class EpisodeCoverResolver
  attr_reader :temp_files, :warnings

  def initialize(config:, logger:, staging_dir:, base_name:, cli_image: nil,
    cli_base_image: nil, feed_image: nil, image_none: false,
    feed_base_image: nil, feed_cover_opts: nil,
    rss_episode_image: nil, youtube_thumbnail: nil,
    episode_description: "")
    @config = config
    @logger = logger
    @staging_dir = staging_dir
    @base_name = base_name
    @cli_image = cli_image
    @cli_base_image = cli_base_image
    @feed_image = feed_image
    @image_none = image_none
    @feed_base_image = feed_base_image
    @feed_cover_opts = feed_cover_opts
    @rss_episode_image = rss_episode_image
    @youtube_thumbnail = youtube_thumbnail
    @episode_description = episode_description
    @temp_files = []
    @warnings = []
  end

  # Returns [path, label]; path is nil when no cover source resolves.
  def resolve(title)
    cli_auto = @cli_image == "auto"
    feed_auto = @feed_image == "auto"
    if cli_auto || feed_auto
      winner = try_auto_cover(title)
      label = cli_auto ? "--image auto (winner)" : "feed image: auto (winner)"
      return [winner, label] if winner
    end
    resolve_without_auto(title)
  end

  # The chain below the auto step — entered directly when auto produced no
  # winner, so the literal string "auto" is never treated as a file path.
  def resolve_without_auto(title)
    feed_image = (@feed_image == "auto") ? nil : @feed_image
    cli_image = (@cli_image == "auto") ? nil : @cli_image

    if cli_image
      if cli_image == "thumb"
        [@youtube_thumbnail, "--image thumb (YouTube thumbnail)"]
      else
        [File.expand_path(cli_image), "--image #{cli_image}"]
      end
    elsif @image_none
      [@youtube_thumbnail, "feed image: none (YouTube thumbnail fallback)"]
    elsif feed_image
      if feed_image == "thumb"
        [@youtube_thumbnail, "feed image: thumb (YouTube thumbnail)"]
      else
        [feed_image, "feed image: #{File.basename(feed_image)}"]
      end
    elsif @cli_base_image
      path = generate_cover_image(title, File.expand_path(@cli_base_image)) || @youtube_thumbnail
      [path, "--base-image title overlay"]
    elsif @feed_base_image
      path = generate_cover_image(title, @feed_base_image) || @youtube_thumbnail
      [path, "feed base_image title overlay"]
    elsif @rss_episode_image
      [@rss_episode_image, "RSS episode image"]
    elsif @config.cover_generation_enabled?
      path = generate_cover_image(title) || @youtube_thumbnail
      [path, "config base_image title overlay"]
    else
      bi = @config.cover_base_image
      if bi && !File.exist?(bi)
        @logger.log("Warning: base_image configured but not found: #{bi}")
      end
      [@youtube_thumbnail, @youtube_thumbnail ? "YouTube thumbnail fallback" : nil]
    end
  end

  private

  # Attempts an auto-cover search for a feed/flag configured with `auto`.
  # Top candidates are persisted into staging_dir (not episodes_dir) so they
  # participate in the pipeline's atomic commit: a crash before
  # commit_episode wipes them along with everything else in staging.
  # Returns the winner's path (in staging_dir) or nil — the caller falls
  # through to the normal cover chain.
  def try_auto_cover(title)
    resolver = AutoCoverResolver.new(config: @config.auto_cover_config, logger: @logger)
    result = resolver.try(
      title: title,
      description: @episode_description,
      episodes_dir: @staging_dir,
      basename: @base_name
    )
    result[:winner_path]
  rescue => e # skippable: cover chain falls through to the next strategy
    @logger.log("Warning: auto cover search failed: #{e.class}: #{e.message}")
    nil
  end

  # Generates a per-episode cover image with the title overlaid on the base
  # image. Returns the generated image path, or nil on failure.
  def generate_cover_image(title, base_image = nil)
    base_image ||= @config.cover_base_image
    unless base_image
      @logger.log("Warning: No base_image configured for cover generation")
      return nil
    end

    options = @config.cover_options.merge(@feed_cover_opts || {})
    path = CoverResolver.generate(
      title: title,
      base_image: base_image,
      options: options,
      logger: @logger
    )
    @temp_files << path if path
    path
  rescue => e # skippable: cover chain falls through to the next strategy
    @logger.log("Warning: Cover generation failed: #{e.class}: #{e.message} (falling back)")
    @warnings << "Cover generation failed (#{e.class}: #{e.message})"
    nil
  end
end
