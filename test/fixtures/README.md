# Test fixtures

Recorded real responses, trimmed to the minimum. Recording is LOOP work
(network + keys): `bundle exec rake fixtures:record` (P1-10), run by the
agent when the containing packet is adopted, announced in the plan doc and
reviewed as a diff (CLAUDE.md rule 6). It rewrites the files below and fills
the recorded-at column. Nobody edits fixtures by hand or invents them. Review the diff after recording
(no secrets, no personal data beyond public post text).

Registry (the fixture-exists test reads the backticked paths in column 3):

| source | endpoint | fixture | recorded-at | trimmed | consumed by |
|---|---|---|---|---|---|
| hn | hn.algolia.com/api/v1/search_by_date (query Bitcoin) | `sources/hn/search_by_date.json` | 2026-10-11T11:05:05Z | first 3 hits; `_highlightResult` dropped | test/unit/test_source_fixtures.rb |
| bluesky | bsky.social /xrpc/app.bsky.feed.searchPosts (query Ruby programming) | `sources/bluesky/search_posts.json` | NOT RECORDED | first 3 posts; only uri, author handle/displayName, record text/createdAt, like/repost counts | test/unit/test_source_fixtures.rb |
| x | api.socialdata.tools/twitter/search (query Ruby programming) | `sources/x/search.json` | NOT RECORDED | first 3 tweets; only ids, text, counts, user screen_name/name | test/unit/test_source_fixtures.rb |
| claude_web | Anthropic Messages API, web_search tool (topic Bitcoin ETF latest news) | `sources/claude_web/message.json` | 2026-10-11T11:05:15Z | role, stop_reason; text blocks with first 3 citations; first 3 web_search results (encrypted fields, usage dropped) | test/unit/test_source_fixtures.rb |
| elevenlabs_scribe | api.elevenlabs.io/v1/speech-to-text (scribe_v2, word timestamps; 3.5 s macOS `say` clip, one-off recording, P5-2b) | `transcription/elevenlabs_scribe_words.json` | 2026-10-12T13:42:22Z | transcription_id dropped; 10 words + 9 spacing tokens | test/unit/test_timestamp_persister.rb |
