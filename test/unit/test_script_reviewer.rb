# frozen_string_literal: true

require_relative "../test_helper"
require "agents/script_reviewer"

class TestScriptReviewer < Minitest::Test
  def setup
    @date = Date.new(2026, 4, 7) # Tuesday
    @research_data = [
      {
        topic: "Bitcoin market",
        findings: [
          { title: "Bitcoin hits $70K", url: "https://example.com/btc", summary: "Bitcoin rose to $70,000." }
        ]
      }
    ]
  end

  # --- check_weekday ---

  def test_check_weekday_correct_day_no_issue
    script = make_script(opening: "Tuesday, April 7th, and Bitcoin is up.")
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    weekday_issues = issues.select { |i| i[:check] == "weekday" }
    assert_empty weekday_issues
    assert_equal script[:segments].first[:text], corrected[:segments].first[:text]
  end

  def test_check_weekday_wrong_day_auto_fixes
    script = make_script(opening: "Saturday, April 7th, and Bitcoin is up.")
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    weekday_issues = issues.select { |i| i[:check] == "weekday" }
    assert_equal 1, weekday_issues.length
    assert_equal ScriptReviewer::BLOCKER, weekday_issues.first[:severity]
    assert weekday_issues.first[:auto_fixed]
    assert_includes weekday_issues.first[:message], "Saturday"
    assert_includes weekday_issues.first[:message], "Tuesday"
    assert_includes corrected[:segments].first[:text], "Tuesday, April 7th"
    refute_includes corrected[:segments].first[:text], "Saturday"
  end

  def test_check_weekday_without_suffix
    script = make_script(opening: "Monday, April 7 and Bitcoin is up.")
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    weekday_issues = issues.select { |i| i[:check] == "weekday" }
    assert_equal 1, weekday_issues.length
    assert_includes corrected[:segments].first[:text], "Tuesday, April 7"
  end

  def test_check_weekday_no_date_in_text_no_issue
    script = make_script(opening: "Welcome back. Bitcoin is up today.")
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    weekday_issues = issues.select { |i| i[:check] == "weekday" }
    assert_empty weekday_issues
  end

  def test_check_weekday_invalid_date_ignored
    script = make_script(opening: "Monday, February 30th and things happened.")
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    weekday_issues = issues.select { |i| i[:check] == "weekday" }
    assert_empty weekday_issues
  end

  def test_check_weekday_does_not_mutate_original
    script = make_script(opening: "Saturday, April 7th, and Bitcoin is up.")
    original_text = script[:segments].first[:text].dup
    reviewer = build_reviewer

    reviewer.run_deterministic_checks(script)

    assert_equal original_text, script[:segments].first[:text]
  end

  # --- check_title_length ---

  def test_check_title_length_under_40_no_issue
    script = make_script(title: "Bitcoin Hits New High")
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    title_issues = issues.select { |i| i[:check] == "title_length" }
    assert_empty title_issues
    assert_equal "Bitcoin Hits New High", corrected[:title]
  end

  def test_check_title_length_exactly_40_no_issue
    title = "A" * 40
    script = make_script(title: title)
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    title_issues = issues.select { |i| i[:check] == "title_length" }
    assert_empty title_issues
  end

  def test_check_title_length_over_40_auto_fixes
    title = "AI Power Plays, Bitcoin ETF Reversals, and the Tokenization Race"
    script = make_script(title: title)
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    title_issues = issues.select { |i| i[:check] == "title_length" }
    assert_equal 1, title_issues.length
    assert_equal ScriptReviewer::BLOCKER, title_issues.first[:severity]
    assert title_issues.first[:auto_fixed]
    assert corrected[:title].length <= 40, "Truncated title '#{corrected[:title]}' should be ≤ 40 chars"
  end

  def test_check_title_truncation_preserves_words
    title = "Robots at the White House, Bitcoin Under Pressure"
    script = make_script(title: title)
    reviewer = build_reviewer

    corrected, _ = reviewer.run_deterministic_checks(script)

    refute corrected[:title].match?(/\w\u2026/), "Should not cut mid-word"
    assert corrected[:title].length <= 40
  end

  def test_check_title_truncation_tries_comma_split
    title = "AI Data Centers Race, Bitcoin Under Pressure"
    script = make_script(title: title)
    reviewer = build_reviewer

    corrected, _ = reviewer.run_deterministic_checks(script)

    assert corrected[:title].length <= 40
    # Should drop after comma if the first part fits
    assert_equal "AI Data Centers Race", corrected[:title]
  end

  # --- check_stage_directions ---

  def test_check_stage_directions_removes_pause_phrase
    script = make_script(segments: [
      { name: "Opening", text: "That approach is smart. Two seconds pause here. Next topic." }
    ])
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    sd_issues = issues.select { |i| i[:check] == "stage_direction" }
    assert_equal 1, sd_issues.length
    assert sd_issues.first[:auto_fixed]
    assert_equal "That approach is smart. Next topic.", corrected[:segments].first[:text]
  end

  def test_check_stage_directions_removes_pause_at_end_of_text
    script = make_script(segments: [
      { name: "Opening", text: "That approach is smart. Two seconds pause here." }
    ])
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    sd_issues = issues.select { |i| i[:check] == "stage_direction" }
    assert_equal 1, sd_issues.length
    assert_equal "That approach is smart.", corrected[:segments].first[:text]
  end

  def test_check_stage_directions_removes_brackets
    script = make_script(segments: [
      { name: "Segment 1", text: "Big news today. [pause] And more news." }
    ])
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    sd_issues = issues.select { |i| i[:check] == "stage_direction" }
    assert_equal 1, sd_issues.length
    assert_equal "Big news today. And more news.", corrected[:segments].first[:text]
  end

  def test_check_stage_directions_removes_parens
    script = make_script(segments: [
      { name: "Segment 1", text: "Consider this. (brief pause) Moving on." }
    ])
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    sd_issues = issues.select { |i| i[:check] == "stage_direction" }
    assert_equal 1, sd_issues.length
    assert_equal "Consider this. Moving on.", corrected[:segments].first[:text]
  end

  def test_check_stage_directions_clean_text_no_issue
    script = make_script(segments: [
      { name: "Opening", text: "Bitcoin rallied to $70,000 on strong ETF inflows." }
    ])
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    sd_issues = issues.select { |i| i[:check] == "stage_direction" }
    assert_empty sd_issues
    assert_equal script[:segments].first[:text], corrected[:segments].first[:text]
  end

  def test_check_stage_directions_preserves_decimals
    # Regression test: decimals like $30.6 million must NOT be split into "$30. 6 million"
    script = make_script(segments: [
      { name: "Opening", text: "Morgan Stanley's ETF pulled in about $30.6 million on day one." },
      { name: "Mining", text: "Hashrate dropped 5.8 percent in Q1, with prices at 27.89 dollars per petahash." }
    ])
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    sd_issues = issues.select { |i| i[:check] == "stage_direction" }
    assert_empty sd_issues, "Decimals must not trigger false stage_direction issues"
    assert_equal script[:segments][0][:text], corrected[:segments][0][:text]
    assert_equal script[:segments][1][:text], corrected[:segments][1][:text]
  end

  def test_check_stage_directions_preserves_abbreviations
    # Regression test: U.S., e.g., i.e. must NOT be split into "U. S."
    script = make_script(segments: [
      { name: "Opening", text: "The U.S. Treasury issued a notice. U.S. lenders remain cautious." }
    ])
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    sd_issues = issues.select { |i| i[:check] == "stage_direction" }
    assert_empty sd_issues, "Abbreviations must not trigger false stage_direction issues"
    assert_equal script[:segments].first[:text], corrected[:segments].first[:text]
  end

  # --- check_markdown ---

  def test_check_markdown_bold_stripped
    script = make_script(segments: [
      { name: "Segment 1", text: "This is **very important** news." }
    ])
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    md_issues = issues.select { |i| i[:check] == "markdown" }
    assert_equal 1, md_issues.length
    assert md_issues.first[:auto_fixed]
    assert_equal "This is very important news.", corrected[:segments].first[:text]
  end

  def test_check_markdown_links_stripped
    script = make_script(segments: [
      { name: "Segment 1", text: "According to [CoinDesk](https://coindesk.com), Bitcoin rose." }
    ])
    reviewer = build_reviewer

    corrected, _ = reviewer.run_deterministic_checks(script)

    assert_equal "According to CoinDesk, Bitcoin rose.", corrected[:segments].first[:text]
  end

  def test_check_markdown_code_stripped
    script = make_script(segments: [
      { name: "Segment 1", text: "The `STRC` token surged." }
    ])
    reviewer = build_reviewer

    corrected, _ = reviewer.run_deterministic_checks(script)

    assert_equal "The STRC token surged.", corrected[:segments].first[:text]
  end

  def test_check_markdown_clean_text_no_issue
    script = make_script(segments: [
      { name: "Opening", text: "Plain text with no formatting at all." }
    ])
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    md_issues = issues.select { |i| i[:check] == "markdown" }
    assert_empty md_issues
  end

  # --- check_forbidden_phrases ---

  def test_check_forbidden_phrases_detected
    script = make_script(segments: [
      { name: "Opening", text: "In today's episode, we cover Bitcoin." }
    ])
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    fp_issues = issues.select { |i| i[:check] == "forbidden_phrase" }
    assert_equal 1, fp_issues.length
    assert_equal ScriptReviewer::WARNING, fp_issues.first[:severity]
    refute fp_issues.first[:auto_fixed]
    assert_includes fp_issues.first[:message], "today's episode"
  end

  def test_check_forbidden_phrases_multiple_detected
    script = make_script(segments: [
      { name: "Opening", text: "In today's episode, let's dive in. Stay tuned!" }
    ])
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    fp_issues = issues.select { |i| i[:check] == "forbidden_phrase" }
    assert_equal 3, fp_issues.length
  end

  def test_check_forbidden_phrases_none_found
    script = make_script(segments: [
      { name: "Opening", text: "Bitcoin rallied to $70,000 on strong ETF inflows." }
    ])
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    fp_issues = issues.select { |i| i[:check] == "forbidden_phrase" }
    assert_empty fp_issues
  end

  # --- check_number_format ---

  def test_check_number_format_spelled_out_detected
    script = make_script(segments: [
      { name: "Segment 1", text: "They raised four hundred million dollars and invested two billion more." }
    ])
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    nf_issues = issues.select { |i| i[:check] == "number_format" }
    assert_equal 1, nf_issues.length
    assert_includes nf_issues.first[:message], "2 spelled-out"
  end

  def test_check_number_format_digits_no_issue
    script = make_script(segments: [
      { name: "Segment 1", text: "They raised $400 million and invested $2 billion more." }
    ])
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    nf_issues = issues.select { |i| i[:check] == "number_format" }
    assert_empty nf_issues
  end

  def test_check_number_format_many_triggers_warning
    script = make_script(segments: [
      { name: "Segment 1", text: "One hundred million here. Two billion there. Three thousand users. Five hundred transactions." }
    ])
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    nf_issues = issues.select { |i| i[:check] == "number_format" }
    assert_equal 1, nf_issues.length
    assert_equal ScriptReviewer::WARNING, nf_issues.first[:severity]
  end

  def test_check_number_format_few_triggers_nit
    script = make_script(segments: [
      { name: "Segment 1", text: "About one hundred users signed up." }
    ])
    reviewer = build_reviewer

    _, issues = reviewer.run_deterministic_checks(script)

    nf_issues = issues.select { |i| i[:check] == "number_format" }
    assert_equal 1, nf_issues.length
    assert_equal ScriptReviewer::NIT, nf_issues.first[:severity]
  end

  # --- check_priority_urls ---

  def test_check_priority_urls_all_present_no_issue
    script = make_script(
      sources: [{ title: "BTC article", url: "https://example.com/btc" }]
    )
    reviewer = build_reviewer(priority_urls: ["https://example.com/btc"])

    _, issues = reviewer.run_deterministic_checks(script)

    pu_issues = issues.select { |i| i[:check] == "priority_url" }
    assert_empty pu_issues
  end

  def test_check_priority_urls_missing_blocker
    script = make_script(
      sources: [{ title: "BTC article", url: "https://example.com/btc" }]
    )
    reviewer = build_reviewer(priority_urls: ["https://other.com/missing"])

    _, issues = reviewer.run_deterministic_checks(script)

    pu_issues = issues.select { |i| i[:check] == "priority_url" }
    assert_equal 1, pu_issues.length
    assert_equal ScriptReviewer::BLOCKER, pu_issues.first[:severity]
    refute pu_issues.first[:auto_fixed]
    assert_includes pu_issues.first[:message], "other.com/missing"
  end

  def test_check_priority_urls_matches_with_different_scheme
    script = make_script(
      sources: [{ title: "Article", url: "https://example.com/btc" }]
    )
    reviewer = build_reviewer(priority_urls: ["http://example.com/btc"])

    _, issues = reviewer.run_deterministic_checks(script)

    pu_issues = issues.select { |i| i[:check] == "priority_url" }
    assert_empty pu_issues
  end

  def test_check_priority_urls_finds_in_segment_sources
    script = make_script(
      sources: [],
      segments: [
        { name: "Seg 1", text: "News.", sources: [{ title: "A", url: "https://example.com/btc" }] }
      ]
    )
    reviewer = build_reviewer(priority_urls: ["https://example.com/btc"])

    _, issues = reviewer.run_deterministic_checks(script)

    pu_issues = issues.select { |i| i[:check] == "priority_url" }
    assert_empty pu_issues
  end

  def test_check_priority_urls_empty_no_issue
    script = make_script
    reviewer = build_reviewer(priority_urls: [])

    _, issues = reviewer.run_deterministic_checks(script)

    pu_issues = issues.select { |i| i[:check] == "priority_url" }
    assert_empty pu_issues
  end

  # --- Integration: multiple fixes ---

  def test_review_deterministic_applies_multiple_fixes
    script = make_script(
      title: "AI Power Plays, Bitcoin ETF Reversals, and the Tokenization Race",
      opening: "Saturday, April 7th. Big news today. [pause] Let's go."
    )
    reviewer = build_reviewer

    corrected, issues = reviewer.run_deterministic_checks(script)

    assert corrected[:title].length <= 40
    assert_includes corrected[:segments].first[:text], "Tuesday"
    refute_includes corrected[:segments].first[:text], "[pause]"
    assert issues.length >= 3 # weekday + title + stage direction
  end

  def test_review_deterministic_does_not_mutate_original
    script = make_script(
      title: "Very Long Title That Exceeds Forty Characters Limit",
      opening: "Saturday, April 7th."
    )
    original_title = script[:title].dup
    original_text = script[:segments].first[:text].dup
    reviewer = build_reviewer

    reviewer.run_deterministic_checks(script)

    assert_equal original_title, script[:title]
    assert_equal original_text, script[:segments].first[:text]
  end

  # --- AI review (mocked) ---

  def test_ai_review_returns_structured_issues
    reviewer = build_reviewer
    mock_issues = [
      ReviewIssue.new(severity: "BLOCKER", check: "hallucination",
                      segment: "Segment 1", message: "Fabricated statistic about ETF inflows")
    ]
    mock_review = ScriptReview.new(
      issues: mock_issues,
      overall_assessment: "Script has factual issues"
    )

    mock_message = stub_api_message(mock_review)

    mock_client = Minitest::Mock.new
    mock_client.expect(:messages, mock_client)
    mock_client.expect(:create, mock_message, [], model: String, max_tokens: Integer,
                       system: String, messages: Array, output_config: Hash)

    reviewer.instance_variable_set(:@client, mock_client)

    script = make_script
    issues = reviewer.send(:run_ai_review, script)

    assert_equal 1, issues.length
    assert_equal "BLOCKER", issues.first[:severity]
    assert_equal "hallucination", issues.first[:check]
    assert_includes issues.first[:message], "ETF inflows"
    refute issues.first[:auto_fixed]
  end

  def test_ai_review_empty_issues_on_good_script
    reviewer = build_reviewer
    mock_review = ScriptReview.new(
      issues: [],
      overall_assessment: "Script looks good"
    )

    mock_message = stub_api_message(mock_review)

    mock_client = Minitest::Mock.new
    mock_client.expect(:messages, mock_client)
    mock_client.expect(:create, mock_message, [], model: String, max_tokens: Integer,
                       system: String, messages: Array, output_config: Hash)

    reviewer.instance_variable_set(:@client, mock_client)

    script = make_script
    issues = reviewer.send(:run_ai_review, script)

    assert_empty issues
  end

  def test_ai_review_prompt_includes_research_data
    reviewer = build_reviewer

    script = make_script
    user_msg = reviewer.send(:build_review_user_message, script)

    assert_includes user_msg, "Bitcoin hits $70K"
    assert_includes user_msg, "example.com/btc"
    assert_includes user_msg, "Bitcoin rose to $70,000"
  end

  def test_ai_review_prompt_includes_date
    reviewer = build_reviewer

    prompt = reviewer.send(:build_review_system_prompt)

    assert_includes prompt, "2026-04-07"
    assert_includes prompt, "Tuesday"
  end

  private

  def make_script(title: "Bitcoin Hits New High", opening: nil, segments: nil, sources: nil)
    segs = segments || [
      { name: "Opening", text: opening || "Tuesday, April 7th, and Bitcoin is rallying." },
      { name: "Bitcoin Rally", text: "Bitcoin surged past $70,000 on strong ETF inflows." },
      { name: "Wrap-Up", text: "That's all for today." }
    ]
    {
      title: title,
      segments: segs,
      sources: sources || [{ title: "BTC article", url: "https://example.com/btc" }]
    }
  end

  def build_reviewer(priority_urls: [])
    ScriptReviewer.new(
      date: @date,
      research_data: @research_data,
      priority_urls: priority_urls,
      guidelines: "Test guidelines",
      logger: nil
    )
  end

  UsageStub = Struct.new(:input_tokens, :output_tokens, :cache_creation_input_tokens, :cache_read_input_tokens)

  def stub_api_message(parsed_output)
    msg = Minitest::Mock.new
    msg.expect(:parsed_output, parsed_output)
    msg.expect(:stop_reason, "end_turn")
    msg.expect(:usage, UsageStub.new(100, 50, 0, 0))
    msg.expect(:model, "claude-opus-4-6")
    msg
  end
end
