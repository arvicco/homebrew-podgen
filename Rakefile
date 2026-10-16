# frozen_string_literal: true

require "rake/testtask"
require "open3"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/*test*.rb"]
end

namespace :test do
  Rake::TestTask.new(:unit) do |t|
    t.libs << "test"
    t.test_files = FileList["test/unit/*test*.rb"]
  end

  Rake::TestTask.new(:integration) do |t|
    t.libs << "test"
    t.test_files = FileList["test/integration/*test*.rb"]
  end

  # Integration files verified to pass with no API keys and no .env —
  # safe for CI. Keyed and live-network cases live in test/api/ (Q-68);
  # a file joins this list only when it has none and sets no
  # process-wide placeholder key (one would un-gate skip_unless_env).
  # CAUTION: `rake test` loads every tier (unit + integration + api) in ONE
  # process, and many unit files set ENV["ANTHROPIC_API_KEY"] ||= "test-key"
  # at load time — so a keyless `rake test` un-gates the test/api cases and
  # runs them with a fake key against live endpoints. Run test:api only
  # with real keys; the gate runs unit and integration_offline as separate
  # processes and is unaffected (fix queued as Q-86).
  Rake::TestTask.new(:integration_offline) do |t|
    t.libs << "test"
    t.test_files = FileList[
      "test/integration/test_assembly.rb",
      "test/integration/test_language_pipeline_chain.rb",
      "test/integration/test_news_pipeline.rb",
      "test/integration/test_pipeline_contracts.rb",
      "test/integration/test_source_registry_drift.rb",
      "test/integration/test_stats_validate.rb",
      "test/integration/test_tell_gloss_pipeline.rb",
      "test/integration/test_tell_speak_pipeline.rb"
    ]
  end

  Rake::TestTask.new(:api) do |t|
    t.libs << "test"
    t.test_files = FileList["test/api/*test*.rb"]
  end

  Rake::TestTask.new(:browser) do |t|
    t.libs << "test"
    t.test_files = FileList["test/browser/*test*.rb"]
  end
end

desc "Probe every registered external endpoint (network; owner-run, never in the gate)"
task :health do
  require "net/http"
  require_relative "lib/source_registry"
  failures = SourceRegistry.entries.reject do |entry|
    uri = URI(entry.probe_url)
    code = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
      open_timeout: 10, read_timeout: 15) { |http| http.get(uri.request_uri).code.to_i }
    ok = case entry.expect
    when :ok then (200..399).cover?(code)
    when :auth then (200..399).cover?(code) || [401, 403].include?(code)
    when :alive then code < 500
    end
    puts format("%-12s %-35s %s (%d)", entry.name, entry.host, ok ? "OK" : "FAIL", code)
    ok
  rescue => e
    puts format("%-12s %-35s FAIL (%s)", entry.name, entry.host, e.class)
    false
  end
  abort "#{failures.size} endpoint(s) unhealthy: #{failures.map(&:name).join(", ")}" unless failures.empty?
  puts "All #{SourceRegistry.entries.size} endpoints healthy"
end

namespace :fixtures do
  desc "Record trimmed real responses of the network sources as test fixtures (network; owner-run, never in the gate)"
  task :record do
    require "dotenv/load"
    require_relative "lib/fixture_recorder"
    failed = FixtureRecorder.new.record_all
    abort "Not recorded: #{failed.join(", ")}" unless failed.empty?
    puts "Recorded #{FixtureRecorder::TARGETS.size} fixtures; review: git diff test/fixtures"
  end
end

desc "Pre-commit gate: syntax + unit + offline integration (all green or no commit)"
task :gate do
  sources = FileList["lib/**/*.rb", "test/**/*.rb", "bin/podgen", "bin/tell", "Rakefile"]
  failed = sources.reject do |f|
    _out, err, status = Open3.capture3(RbConfig.ruby, "-c", f)
    warn err unless status.success?
    status.success?
  end
  abort "Syntax check failed: #{failed.join(", ")}" unless failed.empty?
  puts "Syntax OK (#{sources.size} files)"
  sh "bundle exec standardrb"
  Rake::Task["test:unit"].invoke
  Rake::Task["test:integration_offline"].invoke
end

task default: :test
