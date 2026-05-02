# frozen_string_literal: true

# In-process memoization for RSS + site regeneration.
#
# Per-podcast (keyed by config.name): the first call to ensure_regen runs
# the block; subsequent calls in the same process no-op. Memoization is
# bounded to process lifetime — each fresh `bin/podgen` invocation rebuilds.
#
# Used by PublishCommand and YouTubePublisher so that batch flows like
# `yt-batch` (multiple publish-equivalent calls in one process) regen each
# pod's site/feed once instead of once per call.
module RegenCache
  @done = {}
  @mutex = Mutex.new

  class << self
    def ensure_regen(config)
      key = config.name
      @mutex.synchronize do
        return nil if @done[key]
        @done[key] = true
      end
      yield
    end

    def reset!
      @mutex.synchronize { @done.clear }
    end
  end
end
