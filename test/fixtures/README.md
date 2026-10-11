# Test fixtures

Recorded real responses, trimmed to the minimum. Recording is an OWNER
task (network + keys): `bundle exec rake fixtures:record` (P1-10). It
rewrites the files below and fills the recorded-at column. Agents never
record, edit by hand, or invent fixtures. Review the diff after recording
(no secrets, no personal data beyond public post text).

Registry (the fixture-exists test reads the backticked paths in column 3):

| source | endpoint | fixture | recorded-at | trimmed | consumed by |
|---|---|---|---|---|---|
| hn | hn.algolia.com/api/v1/search_by_date (query Bitcoin) | `sources/hn/search_by_date.json` | 2026-10-11T11:05:05Z | first 3 hits; `_highlightResult` dropped | test/unit/test_source_fixtures.rb |
| bluesky | bsky.social /xrpc/app.bsky.feed.searchPosts (query Ruby programming) | `sources/bluesky/search_posts.json` | NOT RECORDED | first 3 posts; only uri, author handle/displayName, record text/createdAt, like/repost counts | test/unit/test_source_fixtures.rb |
| x | api.socialdata.tools/twitter/search (query Ruby programming) | `sources/x/search.json` | NOT RECORDED | first 3 tweets; only ids, text, counts, user screen_name/name | test/unit/test_source_fixtures.rb |
| claude_web | Anthropic Messages API, web_search tool (topic Bitcoin ETF latest news) | `sources/claude_web/message.json` | 2026-10-11T11:05:15Z | role, stop_reason; text blocks with first 3 citations; first 3 web_search results (encrypted fields, usage dropped) | test/unit/test_source_fixtures.rb |
