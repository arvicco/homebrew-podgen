# frozen_string_literal: true

require_relative "../test_helper"
require "claude_models"
require "anthropic_client"

# P5-1: keyed, network, never in the gate. One call per role the registry
# lowers, on a small fixture, sent exactly as the call site sends it
# (registry model + AnthropicClient.effort_params). Prints input/output
# tokens per role so the effort policy is measured, not pinned blind.
# Run by hand: bundle exec ruby -Ilib:test test/api/test_effort_policy.rb
class TestEffortPolicy < Minitest::Test
  FIXTURES = {
    description: {
      max_tokens: 256,
      system: "You receive ONE title and output ONE title, with category " \
              "prefixes and taglines stripped. Output ONLY the cleaned title.",
      prompt: "PRAVLJICA ZA OTROKE: Lačni medved - mirna pravljica za lahko noč"
    },
    language_detect: {
      max_tokens: 30,
      prompt: "Which of these languages is the following text written in? " \
              "Reply with EXACTLY ONE WORD from this list, no punctuation:\n\n" \
              "Slovenian\nCroatian\n\nText:\nDober dan, kako ste danes? Lepo vreme je."
    }
  }.freeze

  def setup
    skip_unless_env("ANTHROPIC_API_KEY")
    @client = Anthropic::Client.new(timeout: AnthropicClient::REQUEST_TIMEOUT)
  end

  def test_each_lowered_role_succeeds_and_reports_usage
    lowered = ClaudeModels::ROLES.keys.select { |r| ClaudeModels.effort(r) }
    assert_equal FIXTURES.keys.sort, lowered.sort, "every lowered role needs a fixture here"

    rows = lowered.map { |role| measure(role) }
    puts
    puts [["role", "model", "effort", "input", "output", "text"], *rows]
      .map { |r| r.map(&:to_s).zip([16, 20, 7, 8, 8, 0]).map { |s, w| s.ljust(w) }.join(" ") }
  end

  private

  def measure(role)
    fixture = FIXTURES.fetch(role)
    params = {
      model: ClaudeModels.for(role),
      max_tokens: fixture[:max_tokens],
      messages: [{role: "user", content: fixture[:prompt]}],
      **AnthropicClient.effort_params(role)
    }
    params[:system] = fixture[:system] if fixture[:system]
    message = @client.messages.create(**params)
    text = AnthropicClient.text_of(message).strip
    refute_empty text, "#{role}: empty text"
    [role, params[:model], ClaudeModels.effort(role), message.usage.input_tokens,
      message.usage.output_tokens, text.inspect]
  end
end
