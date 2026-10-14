# frozen_string_literal: true

# The one machine-readable line a generate run ends its log with (P7-0):
#
#   RUN-OUTCOME status=ok|warn|error warnings=N errors=M[ first=<text>]
#
# status: error when the run exited non-zero, warn when it succeeded with
# warnings or logged errors, ok otherwise. warnings counts the run's
# degradations (the end-of-run summary plus logged library warnings),
# errors counts ERROR log entries. first is the first error for an error
# run (else the first warning) and the first warning otherwise (else the
# first error), flattened to one line and clipped; it is always the last
# field, so it may contain spaces. `podgen status` reads it before any
# regex scan of the log. Additive to the log; written by GenerateCommand.
module RunOutcome
  PREFIX = "RUN-OUTCOME"
  FIRST_MAX = 200
  LINE_RE = /#{PREFIX} status=(ok|warn|error) warnings=(\d+) errors=(\d+)(?: first=(.*))?\z/

  module_function

  def line(code:, warnings:, errors:, first_error: nil)
    status = if code != 0
      "error"
    elsif warnings.any? || errors.positive?
      "warn"
    else
      "ok"
    end
    # A failed run names what killed it; a degraded one its first warning.
    first = (status == "error") ? first_error || warnings.first : warnings.first || first_error
    text = "#{PREFIX} status=#{status} warnings=#{warnings.size} errors=#{errors}"
    first ? "#{text} first=#{flatten(first)}" : text
  end

  # {status:, warnings:, errors:, first:} or nil when the line is no outcome.
  def parse(text)
    m = text.to_s.chomp.match(LINE_RE)
    return nil unless m

    {status: m[1], warnings: m[2].to_i, errors: m[3].to_i, first: m[4]}
  end

  def flatten(text)
    one = text.to_s.gsub(/\s+/, " ").strip
    (one.length > FIRST_MAX) ? "#{one[0, FIRST_MAX - 3]}..." : one
  end
end
