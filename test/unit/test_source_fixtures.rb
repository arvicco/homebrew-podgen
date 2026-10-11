# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/source_fixture_parsing"
require "fixture_recorder"

# Parse paths of the network sources, offline, from RECORDED fixtures
# (test/fixtures/README.md). Until the owner runs `rake fixtures:record`
# the real-fixture tests skip loudly; the harness itself is proven by the
# SYNTHETIC tests at the bottom (tmpdir only, never committed fixtures).
class TestSourceFixtures < Minitest::Test
  include SourceFixtureParsing

  def test_hn_fixture_parses_to_findings_matching_raw_hits
    body = load_fixture_or_skip("hn/search_by_date.json")

    findings = parse_hn(body)

    assert_finding_shape(findings)
    hit = body["hits"].find { |h| h["title"].to_s.strip != "" }
    first = findings.first
    assert_equal hit["title"].strip, first[:title]
    assert_equal "#{hit["points"] || 0} points, #{hit["num_comments"] || 0} comments on Hacker News", first[:summary]
  end

  def test_bluesky_fixture_parses_to_findings_matching_raw_posts
    body = load_fixture_or_skip("bluesky/search_posts.json")

    findings = parse_bluesky(body)

    assert_finding_shape(findings)
    post = body["posts"].find { |p| p.dig("record", "text").to_s.strip != "" }
    first = findings.first
    assert first[:title].start_with?("@#{post.dig("author", "handle")}: ")
    assert_match(%r{\Ahttps://bsky\.app/profile/#{Regexp.escape(post.dig("author", "handle"))}/post/}, first[:url])
    assert first[:summary].end_with?("[#{post["likeCount"] || 0} likes, #{post["repostCount"] || 0} reposts on Bluesky]")
  end

  def test_x_fixture_parses_to_findings_matching_raw_tweets
    body = load_fixture_or_skip("x/search.json")

    findings = parse_x(body)

    assert_finding_shape(findings)
    tweet = body["tweets"].first
    assert_equal "https://x.com/#{tweet.dig("user", "screen_name")}/status/#{tweet["id_str"]}", findings.first[:url]
    assert findings.first[:summary].end_with?("on X]")
  end

  def test_claude_web_fixture_parses_to_cited_findings
    body = load_fixture_or_skip("claude_web/message.json")

    findings = parse_claude_web(body)

    assert_finding_shape(findings)
    raw_urls = JSON.generate(body).scan(%r{https?://[^"]+})
    findings.each { |f| assert_includes raw_urls, f[:url] }
    assert_equal findings.map { |f| f[:url] }.uniq, findings.map { |f| f[:url] }
  end

  def test_every_fixture_excludes_urls_already_seen
    {
      "hn/search_by_date.json" => :parse_hn,
      "bluesky/search_posts.json" => :parse_bluesky,
      "x/search.json" => :parse_x,
      "claude_web/message.json" => :parse_claude_web
    }.each do |path, parser|
      body = load_fixture_or_skip(path)
      first_url = send(parser, body).first[:url]

      remaining = send(parser, body, exclude: Set[first_url])

      refute_includes remaining.map { |f| f[:url] }, first_url, path
    end
  end

  # Registry check: needs the recording to have happened, so it is opt-in
  # until the owner records (set PODGEN_FIXTURES_RECORDED=1 afterwards, and
  # in CI env once the fixtures are committed).
  def test_every_registered_fixture_exists
    skip_unless_env("PODGEN_FIXTURES_RECORDED")
    readme = File.read(File.join(ROOT, "test", "fixtures", "README.md"))
    paths = readme.scan(/^\|.*`(sources\/[^`]+\.json)`/).flatten

    refute_empty paths
    missing = paths.reject { |p| File.exist?(File.join(ROOT, "test", "fixtures", p)) }
    assert_empty missing, "registered fixtures missing: run rake fixtures:record"
    assert_equal FixtureRecorder::TARGETS.values.map(&:first).sort, paths.map { |p| p.delete_prefix("sources/") }.sort
  end

  def test_readme_registry_matches_recorder_targets
    readme = File.read(File.join(ROOT, "test", "fixtures", "README.md"))
    paths = readme.scan(/^\|.*`sources\/([^`]+\.json)`/).flatten

    assert_equal FixtureRecorder::TARGETS.values.map(&:first).sort, paths.sort
  end

  # ---- SYNTHETIC harness proof: hand-made bodies in a tmpdir. These are NOT
  # recordings and never live under test/fixtures. They prove the loader and
  # parse paths work so a real recording can only fail on real differences.

  def with_synthetic(rel_path, body)
    Dir.mktmpdir do |dir|
      full = File.join(dir, rel_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, JSON.generate(body))
      yield fixture_body(rel_path, root: dir)
    end
  end

  def test_synthetic_hn_body_parses
    body = {"hits" => [
      {"title" => "SYNTHETIC story", "url" => "https://example.test/a", "points" => 7, "num_comments" => 2, "objectID" => "1"},
      {"title" => "SYNTHETIC ask", "url" => nil, "points" => nil, "objectID" => "99"}
    ]}

    with_synthetic("hn/x.json", body) do |loaded|
      findings = parse_hn(loaded)

      assert_finding_shape(findings)
      assert_equal "7 points, 2 comments on Hacker News", findings[0][:summary]
      assert_equal "https://news.ycombinator.com/item?id=99", findings[1][:url]
      assert_equal ["https://news.ycombinator.com/item?id=99"],
        parse_hn(loaded, exclude: Set["https://example.test/a"]).map { |f| f[:url] }
    end
  end

  def test_synthetic_bluesky_body_parses
    body = {"posts" => [{
      "uri" => "at://did:plc:abc/app.bsky.feed.post/rk1",
      "author" => {"handle" => "synthetic.test"},
      "record" => {"text" => "SYNTHETIC post\nsecond line"},
      "likeCount" => 4, "repostCount" => 1
    }]}

    with_synthetic("bluesky/x.json", body) do |loaded|
      f = parse_bluesky(loaded).first

      assert_equal "@synthetic.test: SYNTHETIC post", f[:title]
      assert_equal "https://bsky.app/profile/synthetic.test/post/rk1", f[:url]
      assert f[:summary].end_with?("[4 likes, 1 reposts on Bluesky]")
    end
  end

  def test_synthetic_x_body_parses
    body = {"tweets" => [{
      "id_str" => "42", "full_text" => "SYNTHETIC tweet",
      "user" => {"screen_name" => "synth"}, "favorite_count" => 3, "retweet_count" => 0
    }]}

    with_synthetic("x/x.json", body) do |loaded|
      f = parse_x(loaded).first

      assert_equal "https://x.com/synth/status/42", f[:url]
      assert_equal "@synth: SYNTHETIC tweet", f[:title]
      assert_equal "SYNTHETIC tweet [3 likes, 0 retweets on X]", f[:summary]
    end
  end

  def test_synthetic_claude_web_body_parses_citations_then_search_results
    body = {"content" => [
      {"type" => "web_search_tool_result", "content" => [
        {"type" => "web_search_result", "url" => "https://example.test/r1", "title" => "R1"},
        {"type" => "web_search_result", "url" => "https://example.test/c1", "title" => "dup"}
      ]},
      {"type" => "text", "text" => "SYNTHETIC", "citations" => [
        {"type" => "web_search_result_location", "url" => "https://example.test/c1", "title" => "C1", "cited_text" => "quoted"}
      ]}
    ]}

    with_synthetic("claude_web/x.json", body) do |loaded|
      findings = parse_claude_web(loaded)

      assert_equal ["https://example.test/r1", "https://example.test/c1"], findings.map { |f| f[:url] }
      assert_equal "", findings[0][:summary]
    end
  end

  # Live recording 2026-10-11 wrote an EMPTY hn fixture (zero hits in a 48 h
  # window) and a TRUNCATED claude_web fixture (stop_reason max_tokens, no
  # text block) — both useless. The recorder must refuse such bodies.
  def test_recorder_refuses_empty_or_truncated_bodies
    assert FixtureRecorder.unusable?("hn", {"hits" => []})
    refute FixtureRecorder.unusable?("hn", {"hits" => [{"title" => "t"}]})
    assert FixtureRecorder.unusable?("bluesky", {"posts" => []})
    assert FixtureRecorder.unusable?("x", {"tweets" => []})
    truncated = {"stop_reason" => "max_tokens", "content" => [{"type" => "web_search_tool_result", "content" => []}]}
    assert FixtureRecorder.unusable?("claude_web", truncated)
    no_text = {"stop_reason" => "end_turn", "content" => [{"type" => "web_search_tool_result", "content" => []}]}
    assert FixtureRecorder.unusable?("claude_web", no_text)
    good = {"stop_reason" => "end_turn", "content" => [{"type" => "text", "text" => "x", "citations" => [{"url" => "https://a"}]}]}
    refute FixtureRecorder.unusable?("claude_web", good)
  end

  def test_recorder_hn_window_is_wide_enough_to_find_stories
    assert_operator FixtureRecorder::HN_RECORD_LOOKBACK_SECONDS, :>=, 7 * 86_400
  end

  def test_recorder_does_not_write_an_unusable_fixture
    Dir.mktmpdir do |dir|
      readme = File.join(dir, "README.md")
      File.write(readme, "| hn | `sources/hn/search_by_date.json` | x | NOT RECORDED | t |\n")
      out = StringIO.new
      rec = FixtureRecorder.new(out: out, fixture_dir: dir, readme: readme)
      rec.define_singleton_method(:fetch_hn) { {"hits" => []} }
      failed = rec.record_all
      assert_includes failed, "hn"
      refute File.exist?(File.join(dir, "hn/search_by_date.json")), "empty body must not be written"
      assert_match(/hn\s+FAILED \(unusable/, out.string)
    end
  end

  def test_synthetic_trimmers_keep_first_three_and_drop_noise
    hn = FixtureRecorder.trim_hn({"hits" => 5.times.map { |i| {"title" => "t#{i}", "_highlightResult" => {}} }})
    x = FixtureRecorder.trim_x({"tweets" => 5.times.map { |i| {"id_str" => i.to_s, "user" => {"screen_name" => "u", "secret" => 1}, "junk" => 1} }})
    claude = FixtureRecorder.trim_claude_web({"role" => "assistant", "usage" => {}, "content" => [
      {"type" => "web_search_tool_result", "content" => 5.times.map { |i| {"type" => "web_search_result", "url" => "u#{i}", "encrypted_content" => "zz"} }},
      {"type" => "server_tool_use"}
    ]})

    assert_equal 3, hn["hits"].size
    refute hn["hits"].first.key?("_highlightResult")
    assert_equal 3, x["tweets"].size
    assert_equal({"screen_name" => "u"}, x["tweets"].first["user"])
    refute x["tweets"].first.key?("junk")
    assert_equal 1, claude["content"].size
    assert_equal 3, claude["content"][0]["content"].size
    refute claude["content"][0]["content"][0].key?("encrypted_content")
  end

  def test_synthetic_stamp_readme_fills_only_the_matching_row
    text = "| a | e | `sources/hn/s.json` | NOT RECORDED | t | c |\n| b | e | `sources/x/s.json` | NOT RECORDED | t | c |\n"

    out = FixtureRecorder.stamp_readme(text, "hn/s.json", "2026-01-01T00:00:00Z")

    assert_equal text, FixtureRecorder.stamp_readme(text, "none.json", "z")
    assert_equal text.lines[1], out.lines[1]
    assert_equal "| a | e | `sources/hn/s.json` | 2026-01-01T00:00:00Z | t | c |\n", out.lines[0]
  end
end
