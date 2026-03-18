# frozen_string_literal: true

require_relative "base_validator"

module Validators
  class BaseUrlValidator < BaseValidator
    private

    def check
      unless @config.base_url
        @warnings << "Base URL: not configured"
        return
      end

      if @config.base_url.match?(%r{^https?://})
        @passes << "Base URL: #{@config.base_url}"
      else
        @errors << "Base URL: '#{@config.base_url}' does not start with http:// or https://"
      end
    end
  end
end
