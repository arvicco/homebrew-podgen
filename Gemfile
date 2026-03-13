# frozen_string_literal: true

source "https://rubygems.org"

gem "dotenv",    "~> 3.2"
gem "base64",    "~> 0.3"   # Required by anthropic gem (removed from Ruby 3.4+ defaults)
gem "anthropic", "~> 1.21"  # Official Anthropic Ruby SDK (Claude API)
gem "exa-ai",    "~> 0.8"   # Official Exa.ai Ruby SDK (research/search)
gem "httparty",  "~> 0.24"  # HTTP client for ElevenLabs (no official Ruby SDK)
gem "rexml",     "~> 3.4"   # XML generation for RSS feed (removed from Ruby 4.0 defaults)
gem "rss",       "~> 0.3"   # RSS/Atom feed parsing for RSSSource (removed from Ruby 4.0 defaults)
gem "reline",    "~> 0.6"   # Line editing + history for interactive mode (removed from Ruby 4.0 defaults)
gem "deepl-rb",  "~> 3.0"   # DeepL translation API (for tell tool)
gem "logger",    "~> 1.6"   # Logging (removed from Ruby 4.0 defaults, required by Sinatra)
gem "sinatra",   "~> 4.1"   # Web framework (for tell web UI)
gem "rackup",    "~> 2.2"   # Rack server launcher (required by Sinatra 4+)
gem "puma",      "~> 6.5"   # Threaded web server (SSE streaming for tell web)
gem "ffi-icu",   "~> 0.5"   # ICU transliteration for Cyrillic/Greek/Korean romanization

group :test do
  gem "minitest",  "~> 5.25"
  gem "rake",      "~> 13.2"
  gem "rack-test", "~> 2.2"   # HTTP testing for Sinatra endpoints
end
