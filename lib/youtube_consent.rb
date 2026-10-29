# frozen_string_literal: true

require "time"
require_relative "atomic_writer"

# When the stored YouTube token was consented to (Q-102, P11-2). While the
# OAuth app is in Google's "Testing" status a refresh token dies 7 days
# after the consent. googleauth rewrites the token file at every refresh
# (UserAuthorizer#get_credentials wires on_refresh to store_credentials),
# so the token file's mtime is the last refresh, not the consent: the
# consent time lives in a sidecar beside it. Kept free of the Google gems
# so `podgen status` can read it cheaply.
module YouTubeConsent
  TOKEN_FILE = File.join(Dir.home, ".config", "podgen", "youtube_token.json")

  module_function

  def path(token_file) = "#{token_file}.consent"

  # The recorded consent time, or nil when none is recorded (or unreadable).
  def time(token_file)
    Time.iso8601(File.read(path(token_file)).strip)
  rescue SystemCallError, ArgumentError
    nil
  end

  def record!(token_file, at)
    AtomicWriter.write(path(token_file), "#{at.iso8601}\n")
  end

  def clear!(token_file)
    AtomicWriter.delete_if_exists(path(token_file))
  end
end
