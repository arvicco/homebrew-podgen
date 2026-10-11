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

  # Raises PreflightError when `host` cannot be resolved within `timeout`.
  def self.preflight!(host: DEFAULT_HOST, resolver: Resolv, timeout: DEFAULT_TIMEOUT)
    Timeout.timeout(timeout) { resolver.getaddress(host) }
    nil
  rescue Timeout::Error
    raise PreflightError, "no network: resolving #{host} timed out after #{timeout}s (preflight)"
  rescue Resolv::ResolvError, SocketError => e
    raise PreflightError, "no network: cannot resolve #{host} (#{e.message}) (preflight)"
  end
end
