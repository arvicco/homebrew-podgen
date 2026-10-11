# frozen_string_literal: true

require_relative "../test_helper"
require "claude_models"
require "anthropic"

# P1-0 step 5 (ruling R1-c): keyed, network, never in the gate. Fails when
# the live Models API lists a newer model in a line than the registry
# default — the signal to make the three-line bump in lib/claude_models.rb.
# Run by hand: bundle exec ruby -Ilib:test test/api/test_models_drift.rb
class TestModelsDrift < Minitest::Test
  def setup
    skip_unless_env("ANTHROPIC_API_KEY")
    @models = []
    Anthropic::Client.new.models.list.auto_paging_each do |m|
      @models << { id: m.id.to_s, created_at: m.created_at }
    end
  end

  def test_registry_ids_exist_on_the_api
    live = @models.map { |m| m[:id] }
    ClaudeModels::LINES.each do |line, id|
      assert_includes live, id, "registry #{line} default #{id} is not served by the API"
    end
  end

  def test_each_line_default_is_the_newest_served_model_in_that_line
    ClaudeModels::LINES.each do |line, id|
      newest = @models.select { |m| m[:id].start_with?("claude-#{line}-") }.max_by { |m| m[:created_at] }
      refute_nil newest, "no models served for line #{line}"
      assert_equal newest[:id], id,
        "line #{line}: registry has #{id} but the API's newest is #{newest[:id]} (#{newest[:created_at].to_s[0, 10]}) — bump LINES"
    end
  end
end
