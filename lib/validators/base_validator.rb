# frozen_string_literal: true

require_relative "../format_helper"

module Validators
  class BaseValidator
    def initialize(config)
      @config = config
      @passes = []
      @warnings = []
      @errors = []
    end

    def validate
      check
      { passes: @passes, warnings: @warnings, errors: @errors }
    end

    private

    def check
      raise NotImplementedError, "#{self.class}#check must be implemented"
    end

    def format_size(bytes)
      FormatHelper.format_size(bytes)
    end

    def self.format_size(bytes)
      FormatHelper.format_size(bytes)
    end
  end
end
