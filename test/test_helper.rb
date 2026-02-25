# frozen_string_literal: true

require "bundler/setup"
require "dotenv/load"
require "minitest/autorun"
require "tmpdir"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

def skip_unless_env(*keys)
  missing = keys.reject { |k| ENV[k] && !ENV[k].empty? }
  skip "Missing env: #{missing.join(', ')}" unless missing.empty?
end

def skip_unless_command(cmd)
  skip "#{cmd} not found" unless system("which #{cmd} > /dev/null 2>&1")
end
