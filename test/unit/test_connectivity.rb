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

  # P10-6 (I-10): launchd can fire inside a 2-5 s dark wake; the preflight
  # waits up to 120 s for the network (resolve every 10 s) before failing.
  FAILED_MESSAGE = "no network after 120 s (preflight; the Mac may have been asleep)"

  # Virtual time: the sleeper records each wait and advances the clock.
  def virtual_time
    now = 0.0
    waits = []
    [->(s) {
      waits << s
      now += s
    }, -> { now }, waits]
  end

  def test_preflight_retries_until_the_resolve_succeeds
    sleeper, clock, waits = virtual_time
    calls = 0
    flaky = FakeResolver.new(->(_h) {
      calls += 1
      raise Resolv::ResolvError, "no address" if calls <= 2
      "1.2.3.4"
    })

    assert_nil Connectivity.preflight!(host: "api.example.com", resolver: flaky, sleeper: sleeper, clock: clock)
    assert_equal [10, 10], waits
    assert_equal 3, calls
  end

  def test_preflight_raises_named_error_after_the_wait_budget
    sleeper, clock, waits = virtual_time
    err = assert_raises(Connectivity::PreflightError) do
      Connectivity.preflight!(host: "api.example.com", resolver: FakeResolver.new(Resolv::ResolvError.new("no address")),
        sleeper: sleeper, clock: clock)
    end
    assert_equal FAILED_MESSAGE, err.message
    assert_equal 120, waits.sum, "waits the whole budget, never past it"
  end

  def test_preflight_raises_named_error_when_resolution_hangs
    sleeper, clock, = virtual_time
    slow = FakeResolver.new(->(_h) {
      sleep 0.5
      "1.2.3.4"
    })
    err = assert_raises(Connectivity::PreflightError) do
      Connectivity.preflight!(host: "api.example.com", resolver: slow, timeout: 0.01, sleeper: sleeper, clock: clock)
    end
    assert_equal FAILED_MESSAGE, err.message
  end

  def test_default_host_is_a_registered_endpoint
    require "source_registry"
    assert SourceRegistry::ENTRIES.any? { |e| e.host == Connectivity::DEFAULT_HOST },
      "preflight host must be in the source registry"
  end
end
