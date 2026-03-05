# frozen_string_literal: true

module Tell
  # Shared error formatting for API errors.
  # Extracts human-readable messages from verbose API error JSON.
  module ErrorFormatter
    def friendly_error(err)
      msg = err.message
      if msg.include?('"overloaded_error"') || msg.include?("status: 529")
        "API overloaded (try again)"
      elsif msg.include?('"rate_limit_error"') || msg.include?("status: 429")
        "rate limited (try again)"
      elsif (status = msg[/status[":]\s*(\d{3})/, 1]) && (detail = msg[/"message":\s*"([^"]+)"/, 1])
        "HTTP #{status}: #{detail}"
      else
        msg.length > 80 ? "#{msg[0, 77]}..." : msg
      end
    end
  end
end
