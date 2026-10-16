# frozen_string_literal: true

require_relative "../test_helper"
require "prism"
require "yaml"

# P8-6 (Q-70): ARCHITECTURE "Error severity" makes the bucket annotation
# mandatory at every broad rescue site. This lint enforces it over
# lib/**/*.rb (lib/tell/ included).
#
# Broad = `rescue` with no class, `rescue => e`, `rescue StandardError`,
# `rescue Exception`, and every modifier `stmt rescue x`. Narrow-class
# rescues (`rescue Foo::Error`, `rescue *classes`) are out of scope.
# Annotated = a comment naming skippable|fatal|retryable on the rescue
# line itself, in the comment block directly above it, or (clause rescues
# only) in the comment block that opens the rescue body.
#
# Sites are keyed "file#method" (enclosing def, else enclosing
# class/module, else <main>) with a count, so unrelated edits never churn
# the allowlist. The allowlist (error_policy_allowlist.yml) only shrinks:
# a new unannotated site fails, and so does an allowlisted one that is
# now annotated.
class TestErrorPolicyLint < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  ALLOWLIST_PATH = File.join(__dir__, "error_policy_allowlist.yml")
  BUCKET = /#.*\b(?:skippable|fatal|retryable)\b/
  BROAD_CLASSES = %w[StandardError Exception].freeze

  # Collects [line, enclosing-scope name] for every broad rescue.
  class BroadRescueVisitor < Prism::Visitor
    attr_reader :sites

    def initialize
      @scopes = []
      @sites = []
      super
    end

    def visit_def_node(node)
      name = node.receiver ? "#{node.receiver.slice}.#{node.name}" : node.name.to_s
      within(name) { super }
    end

    def visit_class_node(node) = within("<#{node.constant_path.slice}>") { super }

    def visit_module_node(node) = within("<#{node.constant_path.slice}>") { super }

    def visit_rescue_node(node)
      @sites << [node.keyword_loc.start_line, scope, true] if broad?(node.exceptions)
      super
    end

    def visit_rescue_modifier_node(node)
      @sites << [node.keyword_loc.start_line, scope, false]
      super
    end

    private

    def within(name)
      @scopes.push(name)
      yield
    ensure
      @scopes.pop
    end

    # Innermost def wins; outside any def, the innermost class/module.
    def scope = @scopes.reverse.find { !it.start_with?("<") } || @scopes.last || "<main>"

    def broad?(exceptions)
      exceptions.empty? || exceptions.any? do |ex|
        (ex.is_a?(Prism::ConstantReadNode) || ex.is_a?(Prism::ConstantPathNode)) &&
          BROAD_CLASSES.include?(ex.slice.delete_prefix("::"))
      end
    end
  end

  # => [[line, scope], ...] for broad rescues that carry no bucket comment.
  def self.unannotated_sites(source)
    result = Prism.parse(source)
    lines = source.lines
    visitor = BroadRescueVisitor.new
    result.value.accept(visitor)
    visitor.sites.reject { |line, _, clause| annotated?(lines, line, clause) }.map { it.first(2) }
  end

  def self.annotated?(lines, line, clause)
    return true if lines[line - 1].to_s.match?(BUCKET)
    return true if comment_block(lines, line - 2, -1).any? { it.match?(BUCKET) }
    clause && comment_block(lines, line, 1).any? { it.match?(BUCKET) }
  end

  # Consecutive comment-only lines from index i walking by step.
  def self.comment_block(lines, i, step)
    block = []
    while i >= 0 && i < lines.size && lines[i].lstrip.start_with?("#")
      block << lines[i]
      i += step
    end
    block
  end

  # => {"lib/x.rb#meth" => count} over every lib/**/*.rb
  def self.unannotated_counts(root = ROOT)
    Dir.glob(File.join(root, "lib", "**", "*.rb")).sort.each_with_object(Hash.new(0)) do |path, counts|
      rel = path.delete_prefix(root + "/")
      unannotated_sites(File.read(path)).each { |_line, scope| counts["#{rel}##{scope}"] += 1 }
    end
  end

  def self.violations(counts, allowlist)
    (counts.keys | allowlist.keys).sort.filter_map do |key|
      have = counts.fetch(key, 0)
      allowed = allowlist.fetch(key, 0)
      file, meth = key.split("#", 2)
      if have > allowed
        "#{file} in #{meth}: #{have - allowed} broad rescue(s) without a bucket comment — " \
          "add `# skippable: …`, `# fatal: …` or `# retryable: …` on the rescue line (or the comment line above/below it) " \
          "(ARCHITECTURE: Error severity), and log e.class in any warning it prints"
      elsif have < allowed
        fix = have.zero? ? "remove it from the allowlist" : "lower its allowlist count to #{have}"
        "#{key} is allowlisted for #{allowed} unannotated site(s) but has #{have} — " \
          "#{fix} (test/unit/error_policy_allowlist.yml)"
      end
    end
  end

  def allowlist = YAML.safe_load_file(ALLOWLIST_PATH) || {}

  def sites(src) = self.class.unannotated_sites(src)

  # --- the repo itself ---

  def test_lib_broad_rescues_carry_a_bucket_annotation_or_shrinking_allowlist_entry
    problems = self.class.violations(self.class.unannotated_counts, allowlist)
    assert_empty problems, "error-policy lint:\n#{problems.join("\n")}"
  end

  # --- the scanner ---

  def test_unannotated_sites_bare_clause_rescue_flagged
    src = "def fetch\n  get\nrescue => e\n  warn e.message\nend\n"
    assert_equal [[3, "fetch"]], sites(src)
  end

  def test_unannotated_sites_broad_forms_all_flagged
    src = <<~RUBY
      class Foo
        def a
          x
        rescue
          nil
        end

        def self.b
          y
        rescue StandardError => e
          e
        end

        def c = (z rescue nil)
      end
      begin
        w
      rescue ::Exception
        nil
      end
    RUBY
    assert_equal [[4, "a"], [10, "self.b"], [14, "c"], [18, "<main>"]], sites(src)
  end

  def test_unannotated_sites_narrow_rescues_out_of_scope
    src = "def a\n  x\nrescue Errno::ENOENT, JSON::ParserError => e\n  nil\nrescue *ERRORS\n  nil\nend\n"
    assert_empty sites(src)
  end

  def test_unannotated_sites_bucket_on_line_or_comment_block_above_accepted
    src = <<~RUBY
      def a
        x
      rescue => e # skippable: enrichment
        nil
      end

      def b
        y
        # fatal: no canonical output
        # (second line of the explanation)
      rescue => e
        raise
      end

      def c = (z rescue nil) # retryable: next run retries
    RUBY
    assert_empty sites(src)
  end

  def test_unannotated_sites_bucket_opening_clause_body_accepted_modifier_not
    src = <<~RUBY
      def a
        x
      rescue => e
        # skippable: one engine down; the others carry the run.
        nil
      end

      def b
        y rescue nil
        # skippable: this comment belongs to the next statement
        z
      end
    RUBY
    assert_equal [[9, "b"]], sites(src)
  end

  def test_unannotated_sites_comment_without_bucket_or_not_adjacent_flagged
    src = "def a\n  # skippable: stale\n  x\n  # just a note\nrescue => e\n  nil\nend\n"
    assert_equal [[5, "a"]], sites(src)
  end

  def test_unannotated_sites_rescue_in_block_outside_def_keyed_by_class
    src = "class Foo\n  HOOK = -> { x rescue nil }\nend\n"
    assert_equal [[2, "<Foo>"]], sites(src)
  end

  # --- the allowlist ratchet ---

  def test_violations_new_unannotated_site_names_file_method_and_expected_comment
    problems = self.class.violations({"lib/x.rb#fetch" => 1}, {})
    assert_equal 1, problems.size
    assert_match(/lib\/x\.rb in fetch: 1 broad rescue/, problems.first)
    assert_match(/# skippable: …`, `# fatal: …` or `# retryable: …`/, problems.first)
  end

  def test_violations_allowlisted_site_now_annotated_demands_removal
    problems = self.class.violations({}, {"lib/x.rb#fetch" => 1})
    assert_equal ["lib/x.rb#fetch is allowlisted for 1 unannotated site(s) but has 0 — " \
      "remove it from the allowlist (test/unit/error_policy_allowlist.yml)"], problems
  end

  def test_violations_allowlisted_site_partly_annotated_demands_lower_count
    problems = self.class.violations({"lib/x.rb#fetch" => 1}, {"lib/x.rb#fetch" => 3})
    assert_match(/lower its allowlist count to 1/, problems.first)
  end

  def test_violations_matching_counts_clean
    assert_empty self.class.violations({"lib/x.rb#fetch" => 2}, {"lib/x.rb#fetch" => 2})
  end
end
