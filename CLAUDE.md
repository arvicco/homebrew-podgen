# Podcast Agent — Claude Code Instructions

## Project Overview

Ruby 3.2+, macOS. Dependencies: ffmpeg, yt-dlp, ImageMagick+librsvg, espeak-ng (optional), libicu (optional).

Two pipelines + standalone tool:
1. **News** (`type: news`): Research → Claude script (with source tracking) → ElevenLabs TTS → multi-language MP3s. Entry: `lib/cli/generate_command.rb`. Optional `## Links` in guidelines controls source URL display: `position: bottom` (default, single section at end) or `position: inline` (per-segment), with configurable `title` and `max` limit.
2. **Language** (`type: language`): RSS/YouTube/local MP3 → multi-engine STT → Claude reconciliation → trim → clean MP3 + transcript. Entry: `lib/cli/language_pipeline.rb`. Optional `--youtube` flag generates video (cover+audio MP4), SRT subtitles from transcription timestamps, and uploads to YouTube via Data API v3.
3. **Tell** (`lib/tell/`): Standalone TTS pronunciation CLI + Sinatra web UI with auto-translation and grammatical glossing.

Config per podcast in `podcasts/<name>/guidelines.md` (parsed by `GuidelinesParser`). See README.md for user-facing documentation and `ARCHITECTURE.md` for design rationale behind non-obvious choices.

## Work Protocol

### STOP AND PLAN before touching code

**The moment a bug is reported or a feature is requested, your first action is NOT to edit code.** It is to plan.

This applies to *every* bug report ("X is broken", "Y doesn't work", "why is Z…") and *every* feature request ("add…", "make it…", "can you…"). No exceptions for cases that feel obvious — those are exactly the ones where monkey-patching goes wrong.

Required sequence:
1. **Read the relevant code.** Never rely on assumptions or memory of what the code does.
2. **For bugs:** think through root causes explicitly. List multiple hypotheses. Run read-only commands (grep, logs, traces) to gather evidence. Present a diagnosis with your reasoning.
3. **For features:** describe the proposed approach, the files you'll touch, and what tests you'll add. Identify unknowns and ask clarifying questions.
4. **Wait for explicit approval** before making any code changes.
5. **Write a failing test first** — regression test for bugs, behavior spec for features. Confirm it fails for the *right* reason.
6. **Then implement.** Smallest change that turns the test green.

Anti-patterns to catch yourself committing:
- "Let me just quickly fix…" → no. Stop. Plan first.
- "This might help…" → no. Speculative fixes are not allowed. If you don't know the root cause, say so and ask.
- "I'll add the test after…" → no. Test first, always.

### For all tasks
- **Never change behavior beyond what was explicitly requested.** No drive-by refactors, no unsolicited "improvements."
- **Establish a green baseline** — run the relevant tests before your first code change, so you can distinguish your regressions from pre-existing failures.
- **Run tests after every change.** Keep the codebase green between commits.
- **Work in small, testable increments.** Each step should leave the codebase passing. Prefer multiple small commits over one large change.

## Testing & TDD

TDD is the default loop, not a ceremony. **Red → Green → Refactor**, every time:

1. **Red** — write a test that specifies the desired behavior (or reproduces the bug) and watch it fail for the *right* reason.
2. **Green** — the simplest implementation that makes the test pass. Resist adding scope.
3. **Refactor** — clean up with tests green. Behavior unchanged. Separate commit.

**Production code without a corresponding test should not ship.** If you believe an exception is warranted, state it explicitly and get approval — do not skip the test silently.

**Every failing test is a bug signal.** Investigate to root cause, whether it's from your change or pre-existing. If pre-existing, flag it to the user — never dismiss, skip, or treat it as acceptable background noise.

### Commands
- Framework: Minitest (`test/unit/`, `test/integration/`, `test/api/`)
- Run single file: `bundle exec ruby -Ilib:test test/unit/test_tell_glosser.rb`
- Run unit tests: `rake test:unit`
- Run all tests: `rake test`

### Test tiers
- **Unit** (`test/unit/`): All new classes, modules, and non-trivial methods. No network, no filesystem side-effects. Fast and isolated.
- **Integration** (`test/integration/`): Interactions between components (pipeline contracts, assembly).
- **API** (`test/api/`): Tests hitting real external services, gated behind `skip_unless_env`.

### Conventions
- Test method naming: `test_<method_or_behavior>_<scenario>_<expected_outcome>` (e.g., `test_parse_with_empty_input_returns_default`).
- Structure within each test: Arrange → Act → Assert.

## Coding Standards
- Single responsibility per class/method.
- **Refactoring is a deliberate, separate step** — after tests are green, no external behavior change, its own commit. Drive-by refactors during feature work are not allowed.
- API calls: retry with exponential backoff via `Retryable` mixin (`with_retries`); HTTP calls via `HttpRetryable` (`with_http_retries`); keys from ENV only.
- Paths: `File.join` + `__dir__`-relative, `require_relative` throughout.
- Atomic writes (temp + rename) for history/cache.
- Shell commands: `Open3.capture3` (capture stdout, stderr, status).
- Gems pinned `~> x.y`.
- TTS splitting order: paragraph → sentence → comma → whitespace → UTF-8-safe char boundary.

## Workflow Notes
- When user mentions screenshots or pics, check ~/Desktop for recent .png files sorted by date.
- "Document" means update both CLAUDE.md and README.md.
- "CRPR" means commit, review, push, release — the default release workflow (see below).
- "CPR" means commit, push, release — skips review, only when explicitly requested.

### CRPR — Code Review Workflow
1. **Commit** changes as normal.
2. **Review** — spawn a worktree agent (`isolation: "worktree"`) running the `/cr` skill. The reviewer operates in a separate session with no shared context from the coding session. It is report-only — it never modifies code.
3. **Resolve** — the main session must address all BLOCKERs and WARNINGs flagged by the reviewer. After fixes, commit again and re-run review. **Repeat until the reviewer returns APPROVED or APPROVED WITH WARNINGS.** NITs are optional and do not block.
4. **Push** to origin — CI runs unit tests automatically (`.github/workflows/ci.yml`).
5. **Verify CI** — check CI status via `gh run list` or the GitHub MCP plugin. Do not proceed to release until CI is green. If CI fails, diagnose, fix, commit, and re-push.
6. **Release** — create GitHub release via `gh release create`. Homebrew formula is auto-updated by CI (`.github/workflows/homebrew.yml`).

The review loop (steps 2–3) is mandatory unless the user explicitly says "CPR" or "skip review." Never skip it silently.

### CI/CD
- **CI** (`.github/workflows/ci.yml`): Runs `rake test:unit` on every push to master and on PRs.
- **CD** (`.github/workflows/homebrew.yml`): When a GitHub release is published, auto-computes the tarball SHA256 and updates `Formula/podgen.rb`.
