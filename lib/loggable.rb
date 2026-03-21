# frozen_string_literal: true

# Mixin that provides a `log` method using the injected @logger.
# Derives a tag from the class name (e.g. "[TTSAgent]", "[Transcription::GroqEngine]").
# Falls back to puts when no logger is set.
#
# Usage:
#   class MyAgent
#     include Loggable
#     def initialize(logger: nil)
#       @logger = logger
#     end
#   end
module Loggable
  private

  def log(message)
    tag = "[#{self.class.name&.split('::')&.last || self.class.name}]"
    if @logger
      @logger.log("#{tag} #{message}")
    else
      puts "#{tag} #{message}"
    end
  end

  # Times a block and returns [result, elapsed_seconds].
  #   message, elapsed = measure_time { @client.messages.create(...) }
  def measure_time
    start = Time.now
    result = yield
    elapsed = (Time.now - start).round(2)
    [result, elapsed]
  end
end
