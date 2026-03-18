# frozen_string_literal: true

require_relative "base_validator"

module Validators
  class NewsPipelineValidator < BaseValidator
    private

    def check
      if File.exist?(@config.queue_path)
        @passes << "News: queue.yml present"
      else
        @warnings << "News: queue.yml not found (no fallback topics)"
      end
    end
  end
end
