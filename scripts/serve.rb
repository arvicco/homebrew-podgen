#!/usr/bin/env ruby
# frozen_string_literal: true

# Static file server for podcast output.
# Serves all podcasts under output/ with correct MIME types.
#
# Usage: ruby scripts/serve.rb [port]
#   Default port: 8080

require "webrick"

port = (ARGV[0] || 8080).to_i

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "podcast_config"

doc_root = File.join(PodcastConfig.root, "output")

extra_types = {
  "mp3"  => "audio/mpeg",
  "xml"  => "application/rss+xml",
  "md"   => "text/markdown; charset=utf-8",
  "json" => "application/json"
}

mime_types = WEBrick::HTTPUtils::DefaultMimeTypes.merge(extra_types)

server = WEBrick::HTTPServer.new(
  Port: port,
  DocumentRoot: doc_root,
  MimeTypes: mime_types,
  AccessLog: [],
  Logger: WEBrick::Log.new($stdout, WEBrick::Log::INFO)
)

trap("INT")  { server.shutdown }
trap("TERM") { server.shutdown }

server.start
