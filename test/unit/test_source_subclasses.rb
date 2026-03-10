# frozen_string_literal: true

ENV["OPENAI_API_KEY"] ||= "test-key"
ENV["EXA_API_KEY"] ||= "test-key"
ENV["ANTHROPIC_API_KEY"] ||= "test-key"

require_relative "../test_helper"
require "set"
require "sources/hn_source"
require "sources/bluesky_source"
require "sources/x_source"
require "sources/claude_web_source"

# ---------- HNSource ----------

class TestHNSource < Minitest::Test
  def setup
    @source = HNSource.new
  end

  def test_search_topic_parses_hits
    response = {
      "hits" => [
        {
          "title" => "Ruby 4.0 Released",
          "url" => "https://ruby-lang.org/news/4.0",
          "objectID" => "12345",
          "points" => 350,
          "num_comments" => 120
        },
        {
          "title" => "New JIT compiler for Ruby",
          "url" => "https://example.com/jit",
          "objectID" => "12346",
          "points" => 80,
          "num_comments" => 25
        }
      ]
    }

    @source.stub(:request_with_retry, response) do
      findings = @source.send(:search_topic, "Ruby", Set.new)
      assert_equal 2, findings.length

      assert_equal "Ruby 4.0 Released", findings[0][:title]
      assert_equal "https://ruby-lang.org/news/4.0", findings[0][:url]
      assert_equal "350 points, 120 comments on Hacker News", findings[0][:summary]

      assert_equal "New JIT compiler for Ruby", findings[1][:title]
      assert_equal "https://example.com/jit", findings[1][:url]
      assert_equal "80 points, 25 comments on Hacker News", findings[1][:summary]
    end
  end

  def test_search_topic_falls_back_to_hn_url_when_url_nil
    response = {
      "hits" => [
        {
          "title" => "Ask HN: Best languages in 2026?",
          "url" => nil,
          "objectID" => "99999",
          "points" => 50,
          "num_comments" => 30
        }
      ]
    }

    @source.stub(:request_with_retry, response) do
      findings = @source.send(:search_topic, "languages", Set.new)
      assert_equal 1, findings.length
      assert_equal "https://news.ycombinator.com/item?id=99999", findings[0][:url]
    end
  end

  def test_search_topic_falls_back_to_hn_url_when_url_empty
    response = {
      "hits" => [
        {
          "title" => "Show HN: My project",
          "url" => "",
          "objectID" => "88888",
          "points" => 10,
          "num_comments" => 5
        }
      ]
    }

    @source.stub(:request_with_retry, response) do
      findings = @source.send(:search_topic, "projects", Set.new)
      assert_equal 1, findings.length
      assert_equal "https://news.ycombinator.com/item?id=88888", findings[0][:url]
    end
  end

  def test_search_topic_filters_excluded_urls
    response = {
      "hits" => [
        {
          "title" => "Included",
          "url" => "https://example.com/included",
          "objectID" => "1",
          "points" => 10,
          "num_comments" => 5
        },
        {
          "title" => "Excluded",
          "url" => "https://example.com/excluded",
          "objectID" => "2",
          "points" => 20,
          "num_comments" => 10
        }
      ]
    }

    exclude = Set.new(["https://example.com/excluded"])

    @source.stub(:request_with_retry, response) do
      findings = @source.send(:search_topic, "test", exclude)
      assert_equal 1, findings.length
      assert_equal "Included", findings[0][:title]
    end
  end

  def test_search_topic_skips_empty_titles
    response = {
      "hits" => [
        { "title" => "", "url" => "https://example.com/a", "objectID" => "1", "points" => 10, "num_comments" => 5 },
        { "title" => "  ", "url" => "https://example.com/b", "objectID" => "2", "points" => 20, "num_comments" => 10 },
        { "title" => "Valid", "url" => "https://example.com/c", "objectID" => "3", "points" => 30, "num_comments" => 15 }
      ]
    }

    @source.stub(:request_with_retry, response) do
      findings = @source.send(:search_topic, "test", Set.new)
      assert_equal 1, findings.length
      assert_equal "Valid", findings[0][:title]
    end
  end

  def test_search_topic_handles_nil_response
    @source.stub(:request_with_retry, nil) do
      findings = @source.send(:search_topic, "test", Set.new)
      assert_equal [], findings
    end
  end

  def test_search_topic_handles_missing_hits_key
    @source.stub(:request_with_retry, {}) do
      findings = @source.send(:search_topic, "test", Set.new)
      assert_equal [], findings
    end
  end

  def test_search_topic_defaults_points_and_comments_to_zero
    response = {
      "hits" => [
        { "title" => "No stats", "url" => "https://example.com/x", "objectID" => "7" }
      ]
    }

    @source.stub(:request_with_retry, response) do
      findings = @source.send(:search_topic, "test", Set.new)
      assert_equal "0 points, 0 comments on Hacker News", findings[0][:summary]
    end
  end

  def test_available_returns_true
    assert_equal true, @source.send(:available?)
  end
end

# ---------- BlueskySource ----------

class TestBlueskySource < Minitest::Test
  def setup
    @saved_handle = ENV["BLUESKY_HANDLE"]
    @saved_password = ENV["BLUESKY_APP_PASSWORD"]
  end

  def teardown
    ENV["BLUESKY_HANDLE"] = @saved_handle
    ENV["BLUESKY_APP_PASSWORD"] = @saved_password
  end

  def test_available_when_both_env_vars_set
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new
    assert source.send(:available?)
  end

  def test_unavailable_when_handle_missing
    ENV.delete("BLUESKY_HANDLE")
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new
    refute source.send(:available?)
  end

  def test_unavailable_when_password_missing
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV.delete("BLUESKY_APP_PASSWORD")
    source = BlueskySource.new
    refute source.send(:available?)
  end

  def test_unavailable_returns_empty_results
    ENV.delete("BLUESKY_HANDLE")
    ENV.delete("BLUESKY_APP_PASSWORD")
    source = BlueskySource.new
    results = source.research(["AI", "Ruby"])
    assert_equal 2, results.length
    assert_equal [], results[0][:findings]
    assert_equal [], results[1][:findings]
  end

  def test_at_uri_to_url_with_post_uri
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    url = source.send(:at_uri_to_url, "at://did:plc:abc123/app.bsky.feed.post/xyz789", "alice.bsky.social")
    assert_equal "https://bsky.app/profile/alice.bsky.social/post/xyz789", url
  end

  def test_at_uri_to_url_with_non_post_uri
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    url = source.send(:at_uri_to_url, "at://did:plc:abc123/app.bsky.actor.profile/self", "bob.bsky.social")
    assert_equal "https://bsky.app/profile/bob.bsky.social", url
  end

  def test_search_topic_parses_posts
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    response = {
      "posts" => [
        {
          "record" => { "text" => "Exciting news about AI today!" },
          "author" => { "handle" => "alice.bsky.social" },
          "uri" => "at://did:plc:abc123/app.bsky.feed.post/post1",
          "likeCount" => 42,
          "repostCount" => 7
        }
      ]
    }

    source.stub(:request_with_retry, response) do
      findings = source.send(:search_topic, "AI", Set.new)
      assert_equal 1, findings.length
      assert_equal "@alice.bsky.social: Exciting news about AI today!", findings[0][:title]
      assert_equal "https://bsky.app/profile/alice.bsky.social/post/post1", findings[0][:url]
      assert_includes findings[0][:summary], "42 likes, 7 reposts on Bluesky"
    end
  end

  def test_search_topic_truncates_long_title
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    long_text = "A" * 200
    response = {
      "posts" => [
        {
          "record" => { "text" => long_text },
          "author" => { "handle" => "alice.bsky.social" },
          "uri" => "at://did:plc:abc123/app.bsky.feed.post/post1",
          "likeCount" => 0,
          "repostCount" => 0
        }
      ]
    }

    source.stub(:request_with_retry, response) do
      findings = source.send(:search_topic, "test", Set.new)
      # Title is "@handle: truncated_first_line..."
      title_text = findings[0][:title].sub(/^@alice\.bsky\.social: /, "")
      assert_operator title_text.length, :<=, 120
      assert title_text.end_with?("...")
    end
  end

  def test_search_topic_truncates_long_summary
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    long_text = "B" * 600
    response = {
      "posts" => [
        {
          "record" => { "text" => long_text },
          "author" => { "handle" => "alice.bsky.social" },
          "uri" => "at://did:plc:abc123/app.bsky.feed.post/post1",
          "likeCount" => 0,
          "repostCount" => 0
        }
      ]
    }

    source.stub(:request_with_retry, response) do
      findings = source.send(:search_topic, "test", Set.new)
      # Summary is truncated text + " [0 likes, 0 reposts on Bluesky]"
      # The text portion before the stats should be 500 chars (497 + "...")
      summary = findings[0][:summary]
      assert_includes summary, "..."
      assert_includes summary, "[0 likes, 0 reposts on Bluesky]"
    end
  end

  def test_search_topic_skips_empty_text
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    response = {
      "posts" => [
        {
          "record" => { "text" => "" },
          "author" => { "handle" => "alice.bsky.social" },
          "uri" => "at://did:plc:abc123/app.bsky.feed.post/post1",
          "likeCount" => 0,
          "repostCount" => 0
        },
        {
          "record" => { "text" => "Valid post" },
          "author" => { "handle" => "bob.bsky.social" },
          "uri" => "at://did:plc:def456/app.bsky.feed.post/post2",
          "likeCount" => 5,
          "repostCount" => 1
        }
      ]
    }

    source.stub(:request_with_retry, response) do
      findings = source.send(:search_topic, "test", Set.new)
      assert_equal 1, findings.length
      assert_equal "@bob.bsky.social: Valid post", findings[0][:title]
    end
  end

  def test_search_topic_filters_excluded_urls
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    response = {
      "posts" => [
        {
          "record" => { "text" => "Post one" },
          "author" => { "handle" => "alice.bsky.social" },
          "uri" => "at://did:plc:abc123/app.bsky.feed.post/excluded1",
          "likeCount" => 0,
          "repostCount" => 0
        },
        {
          "record" => { "text" => "Post two" },
          "author" => { "handle" => "bob.bsky.social" },
          "uri" => "at://did:plc:def456/app.bsky.feed.post/kept1",
          "likeCount" => 0,
          "repostCount" => 0
        }
      ]
    }

    exclude = Set.new(["https://bsky.app/profile/alice.bsky.social/post/excluded1"])

    source.stub(:request_with_retry, response) do
      findings = source.send(:search_topic, "test", exclude)
      assert_equal 1, findings.length
      assert_equal "@bob.bsky.social: Post two", findings[0][:title]
    end
  end

  def test_search_topic_limits_to_results_per_topic
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    # Create more posts than RESULTS_PER_TOPIC (5)
    posts = (1..10).map do |i|
      {
        "record" => { "text" => "Post number #{i}" },
        "author" => { "handle" => "user#{i}.bsky.social" },
        "uri" => "at://did:plc:id#{i}/app.bsky.feed.post/post#{i}",
        "likeCount" => 0,
        "repostCount" => 0
      }
    end

    source.stub(:request_with_retry, { "posts" => posts }) do
      findings = source.send(:search_topic, "test", Set.new)
      assert_equal BlueskySource::RESULTS_PER_TOPIC, findings.length
    end
  end

  def test_search_topic_handles_nil_response
    ENV["BLUESKY_HANDLE"] = "user.bsky.social"
    ENV["BLUESKY_APP_PASSWORD"] = "secret"
    source = BlueskySource.new

    source.stub(:request_with_retry, nil) do
      findings = source.send(:search_topic, "test", Set.new)
      assert_equal [], findings
    end
  end
end

# ---------- XSource ----------

class TestXSource < Minitest::Test
  def setup
    @saved_key = ENV["SOCIALDATA_API_KEY"]
  end

  def teardown
    ENV["SOCIALDATA_API_KEY"] = @saved_key
  end

  def test_available_when_api_key_set
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new
    assert source.send(:available?)
  end

  def test_unavailable_when_api_key_missing
    ENV.delete("SOCIALDATA_API_KEY")
    source = XSource.new
    refute source.send(:available?)
  end

  def test_unavailable_returns_empty_results
    ENV.delete("SOCIALDATA_API_KEY")
    source = XSource.new
    results = source.research(["AI", "Ruby"])
    assert_equal 2, results.length
    assert_equal [], results[0][:findings]
    assert_equal [], results[1][:findings]
  end

  def test_parse_tweets_basic
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "Breaking: Ruby 4.0 is out with great performance improvements",
        "user" => { "screen_name" => "rubydev" },
        "id_str" => "123456789",
        "favorite_count" => 500,
        "retweet_count" => 120
      }
    ]

    findings = source.send(:parse_tweets, tweets, Set.new)
    assert_equal 1, findings.length
    assert_equal "@rubydev: Breaking: Ruby 4.0 is out with great performance improvements", findings[0][:title]
    assert_equal "https://x.com/rubydev/status/123456789", findings[0][:url]
    assert_includes findings[0][:summary], "500 likes, 120 retweets on X"
  end

  def test_parse_tweets_falls_back_to_text_field
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "",
        "text" => "Fallback text content",
        "user" => { "screen_name" => "user1" },
        "id_str" => "111",
        "favorite_count" => 10,
        "retweet_count" => 2
      }
    ]

    findings = source.send(:parse_tweets, tweets, Set.new)
    assert_equal 1, findings.length
    assert_includes findings[0][:title], "Fallback text content"
  end

  def test_parse_tweets_uses_id_when_id_str_missing
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "Some tweet",
        "user" => { "screen_name" => "user1" },
        "id" => 999888777,
        "favorite_count" => 0,
        "retweet_count" => 0
      }
    ]

    findings = source.send(:parse_tweets, tweets, Set.new)
    assert_equal "https://x.com/user1/status/999888777", findings[0][:url]
  end

  def test_parse_tweets_truncates_long_title
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "X" * 200,
        "user" => { "screen_name" => "verbose" },
        "id_str" => "222",
        "favorite_count" => 0,
        "retweet_count" => 0
      }
    ]

    findings = source.send(:parse_tweets, tweets, Set.new)
    title_text = findings[0][:title].sub(/^@verbose: /, "")
    assert_operator title_text.length, :<=, 120
    assert title_text.end_with?("...")
  end

  def test_parse_tweets_truncates_long_summary
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "Y" * 600,
        "user" => { "screen_name" => "wordy" },
        "id_str" => "333",
        "favorite_count" => 0,
        "retweet_count" => 0
      }
    ]

    findings = source.send(:parse_tweets, tweets, Set.new)
    summary = findings[0][:summary]
    assert_includes summary, "..."
    assert_includes summary, "[0 likes, 0 retweets on X]"
  end

  def test_parse_tweets_skips_empty_text
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "",
        "text" => "",
        "user" => { "screen_name" => "empty" },
        "id_str" => "444",
        "favorite_count" => 0,
        "retweet_count" => 0
      },
      {
        "full_text" => "Valid tweet",
        "user" => { "screen_name" => "real" },
        "id_str" => "555",
        "favorite_count" => 0,
        "retweet_count" => 0
      }
    ]

    findings = source.send(:parse_tweets, tweets, Set.new)
    assert_equal 1, findings.length
    assert_includes findings[0][:title], "Valid tweet"
  end

  def test_parse_tweets_filters_seen_urls
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "Already seen",
        "user" => { "screen_name" => "user1" },
        "id_str" => "666",
        "favorite_count" => 0,
        "retweet_count" => 0
      }
    ]

    seen = Set.new(["https://x.com/user1/status/666"])
    findings = source.send(:parse_tweets, tweets, seen)
    assert_equal 0, findings.length
  end

  def test_parse_tweets_deduplicates_within_batch
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "Same tweet",
        "user" => { "screen_name" => "user1" },
        "id_str" => "777",
        "favorite_count" => 10,
        "retweet_count" => 5
      },
      {
        "full_text" => "Same tweet again",
        "user" => { "screen_name" => "user1" },
        "id_str" => "777",
        "favorite_count" => 10,
        "retweet_count" => 5
      }
    ]

    findings = source.send(:parse_tweets, tweets, Set.new)
    assert_equal 1, findings.length
  end

  def test_parse_tweets_defaults_unknown_screen_name
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new

    tweets = [
      {
        "full_text" => "No user info",
        "user" => {},
        "id_str" => "888",
        "favorite_count" => 0,
        "retweet_count" => 0
      }
    ]

    findings = source.send(:parse_tweets, tweets, Set.new)
    assert_includes findings[0][:title], "@unknown:"
    assert_includes findings[0][:url], "https://x.com/unknown/status/888"
  end

  def test_priority_handles_strip_at_prefix
    ENV["SOCIALDATA_API_KEY"] = "test-key"
    source = XSource.new(priority_handles: ["@alice", "bob"])
    handles = source.instance_variable_get(:@priority_handles)
    assert_equal ["alice", "bob"], handles
  end
end

# ---------- ClaudeWebSource ----------

# Lightweight mock object for simulating Anthropic API response objects.
# Supports both attribute-style access (obj.type) and is not a Hash,
# so extract_findings treats it via the object branch.
MockObj = Struct.new(:type, :text, :citations, :content, :url, :title, :cited_text, keyword_init: true)

# Wrapper that just holds a content array (simulates the API message).
MockMessage = Struct.new(:content, keyword_init: true)

class TestClaudeWebSource < Minitest::Test
  def setup
    # Stub Anthropic::Client.new to avoid actual API initialization issues
    @source = ClaudeWebSource.allocate
    @source.instance_variable_set(:@client, nil)
    @source.instance_variable_set(:@model, "claude-haiku-4-5-20251001")
    @source.instance_variable_set(:@max_results, 5)
    @source.instance_variable_set(:@logger, nil)
  end

  def test_extract_findings_from_hash_style_text_citations
    message = MockMessage.new(content: [
      {
        type: "text",
        text: "Here are some articles about AI.",
        citations: [
          { url: "https://example.com/ai-1", title: "AI Breakthrough", cited_text: "A major AI breakthrough was announced today." },
          { url: "https://example.com/ai-2", title: "ML Update", cited_text: "Machine learning models improved." }
        ]
      }
    ])

    findings = @source.send(:extract_findings, message)
    assert_equal 2, findings.length
    assert_equal "AI Breakthrough", findings[0][:title]
    assert_equal "https://example.com/ai-1", findings[0][:url]
    assert_equal "A major AI breakthrough was announced today.", findings[0][:summary]
    assert_equal "ML Update", findings[1][:title]
    assert_equal "https://example.com/ai-2", findings[1][:url]
  end

  def test_extract_findings_from_object_style_text_citations
    citation1 = MockObj.new(url: "https://example.com/obj-1", title: "Object Title", cited_text: "Object summary text")
    citation2 = MockObj.new(url: "https://example.com/obj-2", title: "Second Title", cited_text: "Second summary")
    block = MockObj.new(type: "text", text: "Some text", citations: [citation1, citation2])
    message = MockMessage.new(content: [block])

    findings = @source.send(:extract_findings, message)
    assert_equal 2, findings.length
    assert_equal "Object Title", findings[0][:title]
    assert_equal "https://example.com/obj-1", findings[0][:url]
    assert_equal "Object summary text", findings[0][:summary]
  end

  def test_extract_findings_from_web_search_tool_result_hash
    message = MockMessage.new(content: [
      {
        type: "web_search_tool_result",
        content: [
          { type: "web_search_result", url: "https://example.com/search-1", title: "Search Result 1" },
          { type: "web_search_result", url: "https://example.com/search-2", title: "Search Result 2" }
        ]
      }
    ])

    findings = @source.send(:extract_findings, message)
    assert_equal 2, findings.length
    assert_equal "Search Result 1", findings[0][:title]
    assert_equal "https://example.com/search-1", findings[0][:url]
    assert_equal "", findings[0][:summary]
  end

  def test_extract_findings_from_web_search_tool_result_objects
    result1 = MockObj.new(type: "web_search_result", url: "https://example.com/r1", title: "Result 1")
    result2 = MockObj.new(type: "web_search_result", url: "https://example.com/r2", title: "Result 2")
    block = MockObj.new(type: "web_search_tool_result", content: [result1, result2])
    message = MockMessage.new(content: [block])

    findings = @source.send(:extract_findings, message)
    assert_equal 2, findings.length
    assert_equal "Result 1", findings[0][:title]
    assert_equal "Result 2", findings[1][:title]
  end

  def test_extract_findings_deduplicates_urls
    message = MockMessage.new(content: [
      {
        type: "text",
        text: "Article info",
        citations: [
          { url: "https://example.com/dup", title: "First Mention", cited_text: "First summary" },
          { url: "https://example.com/dup", title: "Second Mention", cited_text: "Second summary" }
        ]
      }
    ])

    findings = @source.send(:extract_findings, message)
    assert_equal 1, findings.length
    assert_equal "First Mention", findings[0][:title]
  end

  def test_extract_findings_text_citations_take_priority_over_search_results
    message = MockMessage.new(content: [
      {
        type: "text",
        text: "Article info",
        citations: [
          { url: "https://example.com/shared", title: "Citation Title", cited_text: "Citation summary" }
        ]
      },
      {
        type: "web_search_tool_result",
        content: [
          { type: "web_search_result", url: "https://example.com/shared", title: "Search Title" }
        ]
      }
    ])

    findings = @source.send(:extract_findings, message)
    assert_equal 1, findings.length
    # The text citation should win since it's processed first
    assert_equal "Citation Title", findings[0][:title]
    assert_equal "Citation summary", findings[0][:summary]
  end

  def test_extract_findings_skips_empty_urls
    message = MockMessage.new(content: [
      {
        type: "text",
        text: "Info",
        citations: [
          { url: "", title: "Empty URL", cited_text: "Some text" },
          { url: nil, title: "Nil URL", cited_text: "Some text" },
          { url: "https://example.com/valid", title: "Valid", cited_text: "Valid text" }
        ]
      }
    ])

    findings = @source.send(:extract_findings, message)
    assert_equal 1, findings.length
    assert_equal "Valid", findings[0][:title]
  end

  def test_extract_findings_truncates_summary_at_500_chars
    long_cited = "Z" * 600
    message = MockMessage.new(content: [
      {
        type: "text",
        text: "Info",
        citations: [
          { url: "https://example.com/long", title: "Long", cited_text: long_cited }
        ]
      }
    ])

    findings = @source.send(:extract_findings, message)
    assert_equal 500, findings[0][:summary].length
  end

  def test_extract_findings_limits_to_max_results
    citations = (1..10).map do |i|
      { url: "https://example.com/article-#{i}", title: "Article #{i}", cited_text: "Summary #{i}" }
    end

    message = MockMessage.new(content: [
      { type: "text", text: "Many articles", citations: citations }
    ])

    findings = @source.send(:extract_findings, message)
    assert_equal 5, findings.length
  end

  def test_extract_findings_handles_no_citations
    block = MockObj.new(type: "text", text: "Just text, no citations", citations: nil)
    message = MockMessage.new(content: [block])

    findings = @source.send(:extract_findings, message)
    assert_equal 0, findings.length
  end

  def test_extract_findings_handles_empty_content
    message = MockMessage.new(content: [])
    findings = @source.send(:extract_findings, message)
    assert_equal 0, findings.length
  end

  def test_search_topic_filters_excluded_urls
    citation = MockObj.new(url: "https://example.com/excluded", title: "Excluded", cited_text: "text")
    citation2 = MockObj.new(url: "https://example.com/kept", title: "Kept", cited_text: "text")
    block = MockObj.new(type: "text", text: "Info", citations: [citation, citation2])
    message = MockMessage.new(content: [block])

    exclude = Set.new(["https://example.com/excluded"])

    @source.stub(:call_api, message) do
      findings = @source.send(:search_topic, "test", exclude)
      assert_equal 1, findings.length
      assert_equal "Kept", findings[0][:title]
    end
  end

  def test_search_topic_returns_empty_when_call_api_returns_nil
    @source.stub(:call_api, nil) do
      findings = @source.send(:search_topic, "test", Set.new)
      assert_equal [], findings
    end
  end

  def test_max_retries_is_three
    assert_equal 3, ClaudeWebSource::MAX_RETRIES
  end
end
