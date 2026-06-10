# frozen_string_literal: true

require "rake/testtask"

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

task default: :test
