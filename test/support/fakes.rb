# frozen_string_literal: true

# Test fakes shared verbatim by several test files (P18-10). Only fakes that
# were literally identical across files live here; a fake with any
# file-specific behaviour stays in its own test file.

# Stands in for a CLI command class (PodgenCLI.const_get is stubbed to
# return it): constructing it accepts anything and #run is a no-op exit 0.
class FakeCommand
  def initialize(*) = nil
  def run = 0
end

# Logger that records each #log line in #lines.
class LineLogger
  attr_reader :lines

  def initialize = @lines = []
  def log(msg) = @lines << msg
end

# Records the path of every AtomicWriter.write made inside the block while
# still delegating to the real writer, so a test can prove a rewrite goes
# through temp + rename (P19-2). Returns the recorded paths.
def record_atomic_writes
  require "minitest/mock"
  require_relative "../../lib/atomic_writer"
  paths = []
  real = AtomicWriter.method(:write)
  spy = ->(path, content, **opts) {
    paths << path
    real.call(path, content, **opts)
  }
  AtomicWriter.stub(:write, spy) { yield }
  paths
end
