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
  # safe for CI. The full tier leaks fake ENV keys between tests when run
  # keyless in one process, un-gating API tests; run it locally instead.
  Rake::TestTask.new(:integration_offline) do |t|
    t.libs << "test"
    t.test_files = FileList[
      "test/integration/test_assembly.rb",
      "test/integration/test_language_pipeline_chain.rb",
      "test/integration/test_pipeline_contracts.rb",
      "test/integration/test_source_registry_drift.rb",
      "test/integration/test_stats_validate.rb"
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
