# frozen_string_literal: true

require_relative "../test_helper"
require "syntax_check"

# P18-6 (Q-137): the gate's syntax step runs `ruby -wc`, so a new warning
# (an unused variable, a fully silent rescue) fails the gate like a
# syntax error does.
class TestSyntaxCheck < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("syntax_check_test")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def source(name, body)
    path = File.join(@dir, name)
    File.write(path, body)
    path
  end

  def test_failures_clean_file_none
    clean = source("clean.rb", "def f\n  1\nend\n")

    assert_empty SyntaxCheck.failures([clean])
  end

  def test_failures_warning_file_flagged_with_message
    warned = source("warned.rb", "def f\n  x = 1\nend\n")

    failures = SyntaxCheck.failures([warned])

    assert_equal [warned], failures.keys
    assert_includes failures[warned], "warning:"
  end

  def test_failures_syntax_error_flagged
    broken = source("broken.rb", "def f\n")

    assert_equal [broken], SyntaxCheck.failures([broken]).keys
  end
end
