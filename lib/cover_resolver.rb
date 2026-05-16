# frozen_string_literal: true

require "tmpdir"
require_relative "logger"

# Shared cover image lookup and generation utilities.
# Consolidates the find/generate/cleanup pattern used across
# publish_command, language_pipeline, site_generator, and cover_command.
class CoverResolver
  # Canonical text-overlay option keys for cover generation. Used to:
  # - whitelist keys from `## Image` / `## LingQ` into `PodcastConfig#cover_options`,
  # - transfer per-RSS overrides onto each episode hash in `RSSSource`,
  # - extract per-RSS overrides into per-episode opts in `LanguagePipeline`.
  # Adding a new key here makes all three sites pick it up automatically.
  OVERLAY_KEYS = %i[font font_color font_size width gravity x_offset y_offset].freeze

  # Find an existing per-episode cover file (any image extension).
  # Returns the file path or nil.
  def self.find_episode_cover(episodes_dir, basename)
    Dir.glob(File.join(episodes_dir, "#{basename}_cover.*")).first
  end

  # Generate a cover image with title overlay via CoverAgent.
  # Returns the generated temp file path, or nil on failure.
  #
  # Options:
  #   title:       — text to overlay
  #   base_image:  — background image path (required, must exist)
  #   options:     — cover styling options (font, size, etc.)
  #   logger:      — optional logger for warnings
  #   agent_class: — injectable for testing (default: CoverAgent)
  def self.generate(title:, base_image:, options: {}, logger: nil, agent_class: nil)
    return nil unless base_image
    unless File.exist?(base_image)
      (logger || PodcastAgent.logger).log("Warning: base_image not found: #{base_image}")
      return nil
    end

    agent_class ||= begin
      require_relative "agents/cover_agent"
      CoverAgent
    end

    cover_path = File.join(Dir.tmpdir, "podgen_cover_#{Process.pid}_#{Thread.current.object_id}.jpg")
    agent = agent_class.new(logger: logger)
    agent.generate(title: title, base_image: base_image, output_path: cover_path, options: options)
    cover_path
  rescue => e
    (logger || PodcastAgent.logger).log("Warning: Cover generation failed: #{e.message}")
    nil
  end

  # Clean up a temporary cover file. Only deletes files in tmpdir.
  def self.cleanup(path)
    return unless path
    return unless path.start_with?(Dir.tmpdir)

    File.delete(path) if File.exist?(path)
  rescue # rubocop:disable Lint/SuppressedException
  end
end
