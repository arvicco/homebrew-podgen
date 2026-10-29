# frozen_string_literal: true

require "resolv"
require "timeout"

# Network preflight (P1-13, Q-26). A pipeline run with no name resolution
# used to burn hours in stacked retries; one DNS lookup against a
# registered endpoint fails it in seconds with one clear line instead.
# The resolver is injectable so tests never touch the network.
module Connectivity
  class PreflightError < StandardError; end

  DEFAULT_HOST = "api.anthropic.com"
  DEFAULT_TIMEOUT = 5 # seconds
  # launchd can fire inside a 2-5 s dark wake, asleep again before the
  # preflight (I-10); a waking Mac gets this long to bring the network up.
  WAIT_BUDGET = 120 # seconds
  RETRY_INTERVAL = 10 # seconds

  # Resolves `host` (each attempt bounded by `timeout`) every `interval`
  # seconds until it succeeds or the next wait would pass `wait`, then
  # raises PreflightError. `sleeper` and `clock` are injectable for tests.
  def self.preflight!(host: DEFAULT_HOST, resolver: Resolv, timeout: DEFAULT_TIMEOUT,
    wait: WAIT_BUDGET, interval: RETRY_INTERVAL, sleeper: ->(s) { sleep(s) },
    clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    started = clock.call
    loop do
      return nil if resolves?(host, resolver, timeout)
      if clock.call - started + interval > wait
        raise PreflightError, "no network after #{wait} s (preflight; the Mac may have been asleep)"
      end
      sleeper.call(interval)
    end
  end

  def self.resolves?(host, resolver, timeout)
    Timeout.timeout(timeout) { resolver.getaddress(host) }
    true
  rescue Timeout::Error, Resolv::ResolvError, SocketError
    false
  end
  private_class_method :resolves?
end
