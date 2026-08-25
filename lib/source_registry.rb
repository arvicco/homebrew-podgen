# frozen_string_literal: true

# Registry of every hard-coded external service endpoint (dev-loop
# source-registry convention, M00-3). Adding an HTTP call to a new
# host REQUIRES an entry here in the same commit — the gate's drift
# test (test/integration/test_source_registry_drift.rb) fails
# otherwise. Per-podcast RSS feeds are config (guidelines.md), not
# hard-coded endpoints; they are validated by `podgen validate`.
#
# expect: :ok    — probe returns 2xx/3xx without credentials
#         :auth  — endpoint alive but keyed (401/403 acceptable)
#         :alive — any HTTP response < 500 (scraped or root URLs)
#
# Probe all entries (network, owner-run): bundle exec rake health
module SourceRegistry
  Entry = Struct.new(:name, :host, :probe_url, :expect, :used_by, keyword_init: true)

  EXPECTATIONS = [:ok, :auth, :alive].freeze

  ENTRIES = [
    Entry.new(name: "anthropic", host: "api.anthropic.com",
      probe_url: "https://api.anthropic.com/v1/models", expect: :auth,
      used_by: "anthropic_client.rb (SDK)"),
    Entry.new(name: "openai", host: "api.openai.com",
      probe_url: "https://api.openai.com/v1/models", expect: :auth,
      used_by: "openai_client.rb, transcription/openai_engine.rb"),
    Entry.new(name: "elevenlabs", host: "api.elevenlabs.io",
      probe_url: "https://api.elevenlabs.io/v1/voices", expect: :auth,
      used_by: "agents/tts_agent.rb, transcription/elevenlabs_engine.rb, tell/tts.rb"),
    Entry.new(name: "groq", host: "api.groq.com",
      probe_url: "https://api.groq.com/openai/v1/models", expect: :auth,
      used_by: "transcription/groq_engine.rb"),
    Entry.new(name: "google_tts", host: "texttospeech.googleapis.com",
      probe_url: "https://texttospeech.googleapis.com/v1/voices", expect: :auth,
      used_by: "tell/tts.rb"),
    Entry.new(name: "youtube_api", host: "www.googleapis.com",
      probe_url: "https://www.googleapis.com/discovery/v1/apis", expect: :ok,
      used_by: "youtube_uploader.rb (google-apis gem)"),
    Entry.new(name: "lingq", host: "www.lingq.com",
      probe_url: "https://www.lingq.com/api/v3/", expect: :auth,
      used_by: "agents/lingq_agent.rb"),
    Entry.new(name: "hn_algolia", host: "hn.algolia.com",
      probe_url: "https://hn.algolia.com/api/v1/search?query=ping", expect: :ok,
      used_by: "sources/hn_source.rb"),
    Entry.new(name: "bluesky", host: "bsky.social",
      probe_url: "https://bsky.social/xrpc/com.atproto.server.describeServer", expect: :ok,
      used_by: "sources/bluesky_source.rb"),
    Entry.new(name: "socialdata", host: "api.socialdata.tools",
      probe_url: "https://api.socialdata.tools/", expect: :alive,
      used_by: "sources/x_source.rb"),
    Entry.new(name: "exa", host: "api.exa.ai",
      probe_url: "https://api.exa.ai/", expect: :alive,
      used_by: "agents/research_agent.rb (exa gem)"),
    Entry.new(name: "telegram", host: "api.telegram.org",
      probe_url: "https://api.telegram.org/", expect: :alive,
      used_by: "cli/schedule_command.rb (notifications)"),
    Entry.new(name: "cloudflare", host: "api.cloudflare.com",
      probe_url: "https://api.cloudflare.com/client/v4/", expect: :alive,
      used_by: "analytics_client.rb, cli/analytics_command.rb"),
    Entry.new(name: "duckduckgo", host: "duckduckgo.com",
      probe_url: "https://duckduckgo.com/", expect: :alive,
      used_by: "image_searcher.rb (scraped, fragile by nature)")
  ].freeze

  # Non-service hosts that legitimately appear in lib/: XML namespaces,
  # link display/parsing, documentation examples. Never probed.
  IGNORED_HOSTS = %w[
    example.com www.w3.org www.itunes.com www.apple.com purl.org
    podcastindex.org bsky.app x.com youtu.be www.youtube.com
    news.ycombinator.com host.ts.net i.duckduckgo.com
    external-content.duckduckgo.com
  ].freeze

  def self.entries = ENTRIES

  def self.hosts = ENTRIES.map(&:host)

  def self.registered?(host) = hosts.include?(host)

  def self.ignored?(host) = IGNORED_HOSTS.include?(host)
end
