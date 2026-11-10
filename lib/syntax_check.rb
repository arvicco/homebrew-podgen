# frozen_string_literal: true

require "open3"
require "rbconfig"

# The gate's syntax step (P18-6, Q-137): `ruby -wc` on every source, so a
# new parse-time warning (an unused variable, a silently dropped exception)
# fails the gate like a syntax error does. Stdlib only — the Rakefile loads
# it before bundler-managed code.
module SyntaxCheck
  module_function

  # { path => ruby's stderr } for every file that fails to parse or warns.
  def failures(paths)
    paths.each_with_object({}) do |path, out|
      _stdout, err, status = Open3.capture3(RbConfig.ruby, "-wc", path)
      out[path] = err if !status.success? || err.include?("warning:")
    end
  end
end
