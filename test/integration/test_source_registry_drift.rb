# frozen_string_literal: true

# Gate-tier drift check: every hard-coded external host in lib/ must be
# either a registered SourceRegistry entry or an explicitly ignored
# non-service host. Fails when someone adds an endpoint without
# registering it (CLAUDE.md: source-registry convention, M00-3).

require_relative "../test_helper"
require "source_registry"

class TestSourceRegistryDrift < Minitest::Test
  LIB_DIR = File.expand_path("../../lib", __dir__)
  URL_HOST_RE = %r{https?://([a-zA-Z0-9][a-zA-Z0-9.-]*\.[a-zA-Z]{2,})}

  def test_every_hardcoded_host_is_registered_or_ignored
    offenders = Hash.new { |h, k| h[k] = [] }

    Dir.glob(File.join(LIB_DIR, "**", "*.rb")).each do |path|
      File.read(path).scan(URL_HOST_RE).flatten.uniq.each do |host|
        next if SourceRegistry.registered?(host)
        next if SourceRegistry.ignored?(host)

        offenders[host] << Pathname.new(path).relative_path_from(Pathname.new(LIB_DIR)).to_s
      end
    end

    assert_empty offenders,
      "Unregistered external hosts found — add a SourceRegistry entry " \
      "(service endpoint) or an IGNORED_HOSTS entry (namespace/display " \
      "URL) in lib/source_registry.rb:\n" +
        offenders.map { |host, files| "  #{host}: #{files.uniq.join(", ")}" }.join("\n")
  end

  def test_drift_check_catches_seeded_violation
    # The scanner must actually detect an unknown host, not vacuously pass.
    sample = 'HTTParty.get("https://totally-unregistered-service.example-api.io/v1")'
    hosts = sample.scan(URL_HOST_RE).flatten
    assert_equal ["totally-unregistered-service.example-api.io"], hosts
    refute SourceRegistry.registered?(hosts.first)
    refute SourceRegistry.ignored?(hosts.first)
  end
end
