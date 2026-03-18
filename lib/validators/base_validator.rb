# frozen_string_literal: true

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
      if bytes >= 1_000_000_000
        format("%.1f GB", bytes / 1_000_000_000.0)
      elsif bytes >= 1_000_000
        format("%.1f MB", bytes / 1_000_000.0)
      elsif bytes >= 1_000
        format("%d KB", (bytes / 1_000.0).round)
      else
        "#{bytes} B"
      end
    end
  end
end
