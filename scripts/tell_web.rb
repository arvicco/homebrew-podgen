#!/usr/bin/env ruby
# frozen_string_literal: true

# Tell Web UI — serves the tell pronunciation tool over HTTP with SSE streaming.
# Usage: ruby scripts/tell_web.rb [port]

code_root = File.expand_path("..", __dir__)

gemfile = File.join(code_root, "Gemfile")
if File.exist?(gemfile)
  ENV["BUNDLE_GEMFILE"] ||= gemfile
  require "bundler/setup"
end

# Require logger before adding lib/ to load path (lib/logger.rb shadows the gem)
require "logger"

$LOAD_PATH.unshift(File.join(code_root, "lib"))

require "dotenv"
Dotenv.load(File.join(code_root, ".env"), File.expand_path("~/.env"))

require "tell/web"

port = (ARGV[0] || ENV["TELL_WEB_PORT"] || 9090).to_i
bind = ENV.fetch("TELL_WEB_BIND", "localhost")

config = Tell::Config.new
Tell::Web.set :tell_config, config
Tell::Web.set :port, port
Tell::Web.set :bind, bind

$stderr.puts "tell web → http://#{bind}:#{port}"
Tell::Web.run!
