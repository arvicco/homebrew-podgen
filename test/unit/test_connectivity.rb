# frozen_string_literal: true

require_relative "../test_helper"
require "connectivity"

# P1-13 (Q-26): a dead network must fail the run in seconds, not hours.
class TestConnectivity < Minitest::Test
  class FakeResolver
    def initialize(result) = @result = result

    def getaddress(host)
      raise @result if @result.is_a?(Class) || @result.is_a?(Exception)
      @result.respond_to?(:call) ? @result.call(host) : @result
    end
  end

  def test_preflight_passes_when_host_resolves
    assert_nil Connectivity.preflight!(host: "api.example.com", resolver: FakeResolver.new("1.2.3.4"))
  end

  def test_preflight_raises_named_error_when_resolution_fails
    err = assert_raises(Connectivity::PreflightError) do
      Connectivity.preflight!(host: "api.example.com", resolver: FakeResolver.new(Resolv::ResolvError.new("no address")))
    end
    assert_includes err.message, "api.example.com"
    assert_includes err.message, "no network"
  end

  def test_preflight_raises_named_error_when_resolution_hangs
    slow = FakeResolver.new(->(_h) {
      sleep 0.5
      "1.2.3.4"
    })
    err = assert_raises(Connectivity::PreflightError) do
      Connectivity.preflight!(host: "api.example.com", resolver: slow, timeout: 0.05)
    end
    assert_includes err.message, "timed out"
  end

  def test_default_host_is_a_registered_endpoint
    require "source_registry"
    assert SourceRegistry::ENTRIES.any? { |e| e.host == Connectivity::DEFAULT_HOST },
      "preflight host must be in the source registry"
  end
end
