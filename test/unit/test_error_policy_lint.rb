# frozen_string_literal: true

require_relative "../test_helper"
require "prism"

# P8-6 (Q-70): ARCHITECTURE "Error severity" makes the bucket annotation
# mandatory at every broad rescue site. This lint enforces it over
# lib/**/*.rb (lib/tell/ included).
#
# Broad = `rescue` with no class, `rescue => e`, `rescue StandardError`,
# `rescue Exception`, and every modifier `stmt rescue x`. Narrow-class
# rescues (`rescue Foo::Error`, `rescue *classes`) are out of scope.
# Annotated = a real comment (per the parser, so a `#` inside a string
# does not count) that LEADS with skippable|fatal|retryable (after an
# optional `rubocop:… --` directive), placed on the rescue line itself,
# in the comment block directly above it, or (clause rescues only) in the
# comment block that opens the rescue body.
#
# There is no allowlist: every site in lib/ is annotated, so a new
# unannotated site fails the gate, naming file, method and line.
class TestErrorPolicyLint < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BUCKET = /\A#\s*(?:rubocop:\S+.*--\s*)?(?:skippable|fatal|retryable)\b/
  BROAD_CLASSES = %w[StandardError Exception].freeze

  # Collects [line, enclosing-scope name, clause?] for every broad rescue.
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
    comments = result.comments.group_by { it.location.start_line }.transform_values { |cs| cs.map(&:slice) }
    comment_only = comments.keys.select { |l| lines[l - 1].lstrip.start_with?("#") }.to_set
    visitor = BroadRescueVisitor.new
    result.value.accept(visitor)
    visitor.sites.reject { |line, _, clause| annotated?(comments, comment_only, line, clause) }.map { it.first(2) }
  end

  def self.annotated?(comments, comment_only, line, clause)
    candidates = [line] + comment_block(comment_only, line - 1, -1)
    candidates += comment_block(comment_only, line + 1, 1) if clause
    candidates.any? { |l| comments.fetch(l, []).any? { it.match?(BUCKET) } }
  end

  # Consecutive comment-only line numbers from line l walking by step.
  def self.comment_block(comment_only, l, step)
    block = []
    while comment_only.include?(l)
      block << l
      l += step
    end
    block
  end

  # => ["lib/x.rb:12 in meth", ...] over every lib/**/*.rb
  def self.unannotated_in_lib(root = ROOT)
    Dir.glob(File.join(root, "lib", "**", "*.rb")).sort.flat_map do |path|
      rel = path.delete_prefix(root + "/")
      unannotated_sites(File.read(path)).map { |line, scope| "#{rel}:#{line} in #{scope}" }
    end
  end

  def sites(src) = self.class.unannotated_sites(src)

  # --- the repo itself ---

  def test_lib_broad_rescues_carry_a_leading_bucket_comment
    offenders = self.class.unannotated_in_lib
    assert_empty offenders, "broad rescue(s) without a bucket comment — start a comment on the rescue line " \
      "(or the comment line above it, or opening a rescue clause's body) with `# skippable: …`, `# fatal: …` " \
      "or `# retryable: …` (ARCHITECTURE: Error severity), and log e.class in any warning it prints:\n" \
      "#{offenders.join("\n")}"
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

  def test_unannotated_sites_interpolation_hash_is_not_a_comment_flagged
    src = "def a\n  log(\"Warning: \#{x} (non-fatal)\") rescue nil\nend\n"
    assert_equal [[2, "a"]], sites(src)
  end

  def test_unannotated_sites_bucket_word_not_leading_the_comment_flagged
    src = <<~RUBY
      def a
        x rescue nil # not fatal
      end

      def b
        y
        # TODO: fatal or skippable?
      rescue => e
        nil
      end
    RUBY
    assert_equal [[2, "a"], [8, "b"]], sites(src)
  end

  def test_unannotated_sites_leading_bucket_after_rubocop_directive_accepted
    src = <<~RUBY
      def a
        x
      rescue # rubocop:disable Lint/SuppressedException -- skippable: leftover temp file
      end

      def b = (y rescue nil) #   skippable: silent fallback — nil
    RUBY
    assert_empty sites(src)
  end

  def test_unannotated_sites_rescue_in_block_outside_def_keyed_by_class
    src = "class Foo\n  HOOK = -> { x rescue nil }\nend\n"
    assert_equal [[2, "<Foo>"]], sites(src)
  end
end
