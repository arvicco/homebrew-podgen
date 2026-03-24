# Podcast Agent — Claude Code Instructions

## Work Protocol

### For ALL tasks:
1. **Read relevant code** before proposing or making changes — never rely on assumptions
2. **Propose your plan** and wait for explicit approval before implementing
3. **Never change behavior** beyond what was explicitly requested — no drive-by refactors, no "improvements"
4. **Run relevant tests before making changes** to establish a green baseline — you cannot distinguish regressions from pre-existing failures without one
5. **Run tests** after making changes (see Testing below)
6. **All tests must pass.** If a test fails, investigate — never dismiss it as "pre-existing"
7. **Work in small, testable increments.** Each step should leave the codebase in a passing state. Prefer multiple small commits over one large change

### When a bug or problem is reported:
1. **STOP. Do not touch the codebase.**
2. Think through potential root causes — list them explicitly
3. Run exploratory read-only commands (grep, logs, traces) to gather evidence
4. Present a diagnosis with your reasoning and a proposed fix plan
5. Wait for explicit approval before making any code changes
6. Write regression test before implementing any fix

**Never implement a fix speculatively.** "This might help" changes are not allowed.
If you are unsure about the root cause, say so and ask a clarifying question instead of guessing with code.

**Every bug fix must include a regression test** that fails without the fix and passes with it. No fix is complete without one.

## Testing

### Commands
- Framework: Minitest (`test/unit/`, `test/integration/`, `test/api/`)
- Run single file: `bundle exec ruby -Ilib:test test/unit/test_tell_glosser.rb`
- Run unit tests: `rake test:unit`
- Run all tests: `rake test`

### Test-Driven Development
- **Tests first for new behavior:** Write a failing test that specifies the desired behavior → make it pass with the simplest implementation → refactor. (Red → Green → Refactor)
- **Tests first for bug fixes:** Write a failing test that reproduces the bug → fix it → confirm the test passes
- **New production code must have corresponding tests.** Untested code should not be merged without explicit justification

### Test Tiers
- **Unit** (`test/unit/`): All new classes, modules, and non-trivial methods. No network, no filesystem side-effects. Must be fast and isolated
- **Integration** (`test/integration/`): Interactions between components (pipeline contracts, assembly)
- **API** (`test/api/`): Tests hitting real external services, gated behind `skip_unless_env`

### Conventions
- Test method naming: `test_<method_or_behavior>_<scenario>_<expected_outcome>` (e.g., `test_parse_with_empty_input_returns_default`)
- Structure within each test: Arrange → Act → Assert
- **A failing test is a bug signal.** Investigate every failure — determine root cause, whether related to your changes or a separate issue. If separate, flag it to the user
- Never treat failing tests as acceptable background noise

## Coding Standards
- Single responsibility per class/method
- **Refactoring is a deliberate, separate step** — it happens after tests are green, changes no external behavior, and gets its own commit. Drive-by refactors during feature work are still not allowed
- API calls: retry with exponential backoff via `Retryable` mixin (`with_retries`), HTTP calls via `HttpRetryable` (`with_http_retries`), keys from ENV only
- Sources extend `BaseSource` (template method: subclasses implement `search_topic`); `RSSSource` is standalone (different research pattern)
- CLI commands include `PodcastCommand` mixin for podcast name validation (`require_podcast!` — validates existence with did-you-mean suggestions) and config loading (`load_config!`)
- Anthropic API client initialization via `AnthropicClient` mixin (`init_anthropic_client`), token usage logging via `UsageLogger` mixin (`log_api_usage`), timing via `Loggable#measure_time`
- Guidelines parsing via `GuidelinesParser` (extracted from `PodcastConfig`, which delegates all section parsing)
- Episode MP3 filtering via `EpisodeFiltering` module (shared across rss_generator, site_generator, validate, stats, scrap)
- Transcript HTML via `TranscriptRenderer` module (shared by RssGenerator and SiteGenerator). RSS passes `vocab: false` (strips vocabulary, removes bold markers); site uses default `vocab: true` (linked words + rendered definitions)
- Known vocabulary via `KnownVocabulary` class — per-language lemma lists in `known_vocabulary.yml`, managed by `podgen vocab` CLI, filtered in `VocabularyAnnotator` before marking/rendering
- Cognate filtering via deterministic code post-filter in `VocabularyAnnotator#filter_cognates` — ICU transliteration (`Cyrillic-Latin; Latin-ASCII`) + Levenshtein distance with length-adaptive thresholds. Supports Latin and Cyrillic scripts. Prompt-based filtering is unreliable for exclusion tasks; code handles it instead. The LLM provides `similar_translations` field for cross-script comparison
- URL cleaning via `UrlCleaner` module (strips tracking params like utm_*, fbclid, gclid)
- Paths: `File.join` + `__dir__`-relative, `require_relative` throughout
- Atomic writes (temp + rename) for history/cache
- Shell commands: `Open3.capture3` (capture stdout, stderr, status)
- Gems pinned `~> x.y`
- TTS splitting: paragraph → sentence → comma → whitespace → UTF-8-safe char boundary

## Workflow Notes
- When user mentions screenshots or pics, check ~/Desktop for recent .png files sorted by date
- "Document" means update both CLAUDE.md and README.md
- "CRPR" means commit, review, push, release — the default release workflow (see below)
- "CPR" means commit, push, release — skips review, only when explicitly requested

### CRPR — Code Review Workflow
1. **Commit** changes as normal
2. **Review** — spawn a worktree agent (`isolation: "worktree"`) running the `/cr` skill. The reviewer operates in a separate session with no shared context from the coding session. It is report-only — it never modifies code
3. **Resolve** — the main session must address all BLOCKERs and WARNINGs flagged by the reviewer. After fixes, commit again and re-run review. **Repeat until the reviewer returns APPROVED or APPROVED WITH WARNINGS.** NITs are optional and do not block
4. **Push** to origin
5. **Release** — GitHub release + Homebrew formula update

The review loop (steps 2–3) is mandatory unless the user explicitly says "CPR" or "skip review". Never skip it silently.

## Project Overview

Ruby 3.2+, macOS. Dependencies: ffmpeg, yt-dlp, ImageMagick+librsvg, espeak-ng (optional), libicu (optional).

Two pipelines + standalone tool:
1. **News** (`type: news`): Research → Claude script (with source tracking) → ElevenLabs TTS → multi-language MP3s. Entry: `cli/generate_command.rb`. Optional `## Links` in guidelines controls source URL display: `position: bottom` (default, single section at end) or `position: inline` (per-segment), with configurable `title` and `max` limit.
2. **Language** (`type: language`): RSS/YouTube/local MP3 → multi-engine STT → Claude reconciliation → trim → clean MP3 + transcript. Entry: `cli/language_pipeline.rb`
3. **Tell** (`lib/tell/`): Standalone TTS pronunciation CLI + Sinatra web UI with auto-translation and grammatical glossing

Config per podcast in `podcasts/<name>/guidelines.md` (parsed by `GuidelinesParser`). See README.md for full user-facing documentation.
