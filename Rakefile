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

  Rake::TestTask.new(:api) do |t|
    t.libs << "test"
    t.test_files = FileList["test/api/*test*.rb"]
  end
end

task default: :test
