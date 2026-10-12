# frozen_string_literal: true

require_relative "../test_helper"
require "ripper"

# P3-5: internal owner discourse — ruling ids, ruling text, thread ids,
# quoted owner decisions — never reaches a runtime string a user can see.
# Scope matches the owner's 2026-10-12 ruling exactly: string LITERALS
# under lib/ bin/ scripts/. Packet/phase/incident ids in code comments and
# working discourse are allowed and are not scanned here.
class TestRuntimeStringHygiene < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BANNED = [
    /\bR\d+-(?:\d{2}|[a-z])\b/, # ruling ids: R3-01, R1-k, R0-c
    /\bruling\b/i,
    /\bthread[ -]?id\b/i,
    /\bowner (?:said|ruled|decided)\b/i
  ].freeze

  def ruby_files
    Dir.glob(File.join(ROOT, "{lib,bin,scripts}", "**", "*")).select do |f|
      File.file?(f) && (f.end_with?(".rb") || File.open(f, &:readline).to_s.include?("ruby"))
    rescue EOFError
      false
    end
  end

  SHELL_SHEBANG = %r{\A#!\S*(?:/|\s|env\s+)(?:ba)?sh\b}

  # scripts/**/*.sh plus extensionless bin/ and scripts/ files whose first
  # line is an sh/bash shebang.
  def shell_files(root = ROOT)
    sh = Dir.glob(File.join(root, "scripts", "**", "*.sh"))
    extensionless = Dir.glob(File.join(root, "{bin,scripts}", "**", "*")).select do |f|
      File.extname(f).empty? && File.file?(f) && File.open(f, &:readline).to_s.match?(SHELL_SHEBANG)
    rescue EOFError
      false
    end
    (sh + extensionless).select { |f| File.file?(f) }.uniq
  end

  def test_shell_files_include_extensionless_sh_and_bash_shebang_files
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p([File.join(root, "bin"), File.join(root, "scripts")])
      files = {
        "bin/tool" => "#!/bin/bash\necho hi\n", "scripts/job" => "#!/usr/bin/env sh\necho hi\n",
        "scripts/a.sh" => "echo hi\n", "bin/rb" => "#!/usr/bin/env ruby\nputs 1\n",
        "bin/zed" => "#!/bin/zsh\necho hi\n", "bin/empty" => ""
      }
      files.each { |rel, body| File.write(File.join(root, rel), body) }

      found = shell_files(root).map { it.delete_prefix(root + "/") }.sort
      assert_equal %w[bin/tool scripts/a.sh scripts/job], found
    end
  end

  def string_literals(path)
    Ripper.lex(File.read(path)).filter_map do |(line, _col), type, text, _state|
      [line, text] if type == :on_tstring_content
    end
  end

  def test_runtime_string_literals_carry_no_owner_discourse
    offenders = []
    ruby_files.each do |path|
      string_literals(path).each do |line, text|
        BANNED.each { |re| offenders << "#{path.delete_prefix(ROOT + "/")}:#{line}: #{text.strip}" if text.match?(re) }
      end
    end
    shell_files.each do |path|
      File.foreach(path).with_index(1) do |text, line|
        next if text.lstrip.start_with?("#")
        BANNED.each { |re| offenders << "#{path.delete_prefix(ROOT + "/")}:#{line}: #{text.strip}" if text.match?(re) }
      end
    end

    assert_empty offenders, "owner discourse in runtime strings:\n#{offenders.join("\n")}"
  end

  def test_scanner_sees_string_content_not_comments
    src = "# ruling R1-k in a comment is fine\nputs \"no ruling here\"\n"
    literals = Ripper.lex(src).filter_map { |_pos, type, text, _| text if type == :on_tstring_content }

    assert_equal ["no ruling here"], literals
    assert literals.first.match?(BANNED[1])
  end
end
