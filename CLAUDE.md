# Podcast Agent — Claude Code Instructions

## Work Protocol

### For ALL tasks:
1. **Read relevant code** before proposing or making changes — never rely on assumptions
2. **Propose your plan** and wait for explicit approval before implementing
3. **Never change behavior** beyond what was explicitly requested — no drive-by refactors, no "improvements"
4. **Run tests** after making changes (see Testing below)
5. **All tests must pass.** If a test fails, investigate — never dismiss it as "pre-existing"

### When a bug or problem is reported:
1. **STOP. Do not touch the codebase.**
2. Think through potential root causes — list them explicitly
3. Run exploratory read-only commands (grep, logs, traces) to gather evidence
4. Present a diagnosis with your reasoning and a proposed fix plan
5. Wait for explicit approval before making any code changes

**Never implement a fix speculatively.** "This might help" changes are not allowed.
If you are unsure about the root cause, say so and ask a clarifying question instead of guessing with code.

## Testing

- Framework: Minitest (`test/unit/`, `test/integration/`, `test/api/`)
- Run single file: `bundle exec ruby -Ilib:test test/unit/test_tell_glosser.rb`
- Run unit tests: `rake test:unit`
- Run all tests: `rake test`
- **A failing test is a bug signal.** Investigate every failure — determine root cause, whether related to your changes or a separate issue. If separate, flag it to the user
- Never treat failing tests as acceptable background noise

## Coding Standards
- Single responsibility per class/method
- API calls: retry with exponential backoff via `Retryable` mixin (`with_retries`), HTTP calls via `HttpRetryable` (`with_http_retries`), keys from ENV only
- Sources extend `BaseSource` (template method: subclasses implement `search_topic`); `RSSSource` is standalone (different research pattern)
- CLI commands include `PodcastCommand` mixin for podcast name validation (`require_podcast!`) and config loading (`load_config!`)
- Guidelines parsing via `GuidelinesParser` (extracted from `PodcastConfig`, which delegates all section parsing)
- Episode MP3 filtering via `EpisodeFiltering` module (shared across rss_generator, site_generator, validate, stats, scrap)
- Paths: `File.join` + `__dir__`-relative, `require_relative` throughout
- Atomic writes (temp + rename) for history/cache
- Shell commands: `Open3.capture3` (capture stdout, stderr, status)
- Gems pinned `~> x.y`
- TTS splitting: paragraph → sentence → comma → whitespace → UTF-8-safe char boundary

## Workflow Notes
- When user mentions screenshots or pics, check ~/Desktop for recent .png files sorted by date
- "Document" means update both CLAUDE.md and README.md
- "CPR" means commit, push, release (commit → push to origin → GitHub release → update Homebrew formula)

## Project Overview

Ruby 3.2+, macOS. Dependencies: ffmpeg, yt-dlp, ImageMagick+librsvg, espeak-ng (optional), libicu (optional).

Two pipelines + standalone tool:
1. **News** (`type: news`): Research → Claude script → ElevenLabs TTS → multi-language MP3s. Entry: `cli/generate_command.rb`
2. **Language** (`type: language`): RSS/YouTube/local MP3 → multi-engine STT → Claude reconciliation → trim → clean MP3 + transcript. Entry: `cli/language_pipeline.rb`
3. **Tell** (`lib/tell/`): Standalone TTS pronunciation CLI + Sinatra web UI with auto-translation and grammatical glossing

Config per podcast in `podcasts/<name>/guidelines.md` (parsed by `GuidelinesParser`). See README.md for full user-facing documentation.
