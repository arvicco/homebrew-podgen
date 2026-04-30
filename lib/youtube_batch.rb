# frozen_string_literal: true

require_relative "atomic_writer"
require_relative "yaml_loader"

# Picks the next podcast for a batched, one-episode-at-a-time YouTube upload
# round, rotating across multiple podcasts to spread quota usage across days.
#
# Modes:
#   :priority    — first podcast (in given order) with pending uploads.
#                  Stateless; no cursor written.
#   :round_robin — rotates across podcasts, persisting cursor in YAML.
#                  Skips podcasts with nothing pending.
#
# pending_lookup: callable taking a podcast name, returning Integer count
# of episodes pending YouTube upload (>0 means there's work to do).
class YoutubeBatch
  VALID_MODES = %i[priority round_robin].freeze

  def initialize(podcasts:, mode:, cursor_path:, pending_lookup:)
    raise ArgumentError, "podcasts must not be empty" if podcasts.nil? || podcasts.empty?
    raise ArgumentError, "mode must be one of #{VALID_MODES}" unless VALID_MODES.include?(mode)

    @podcasts = podcasts
    @mode = mode
    @cursor_path = cursor_path
    @pending_lookup = pending_lookup
  end

  # Returns the podcast name to upload next, or nil if all are caught up.
  # In :round_robin mode, advances and persists the cursor.
  def next_podcast
    case @mode
    when :priority    then pick_priority
    when :round_robin then pick_round_robin
    end
  end

  private

  def pick_priority
    @podcasts.find { |pod| @pending_lookup.call(pod) > 0 }
  end

  def pick_round_robin
    last_index = read_cursor
    start = last_index.nil? ? 0 : (last_index + 1) % @podcasts.length

    @podcasts.length.times do |offset|
      idx = (start + offset) % @podcasts.length
      pod = @podcasts[idx]
      next unless @pending_lookup.call(pod) > 0

      write_cursor(idx)
      return pod
    end

    nil
  end

  def read_cursor
    data = YamlLoader.load(@cursor_path, default: nil)
    return nil unless data.is_a?(Hash)
    data["last_index"].is_a?(Integer) ? data["last_index"] : nil
  end

  def write_cursor(index)
    AtomicWriter.write_yaml(@cursor_path, { "last_index" => index })
  end
end
