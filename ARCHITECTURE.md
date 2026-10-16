# Architecture & Design Rationale

This document captures **why** the codebase is shaped the way it is. It is not a module inventory — use code navigation for "what exists where." Record a decision here only if the rationale is non-obvious from reading the code and would plausibly get re-litigated without it.

When a decision recorded here is revisited or reversed, update or remove the entry in the same commit as the code change.

---

## Two pipelines, not one generic one

News (`type: news`) and Language (`type: language`) are intentionally separate entry points (`lib/cli/generate_command.rb`, `lib/cli/language_pipeline.rb`) rather than a single parameterised pipeline.

**Why.** The two have almost no overlap in control flow. News goes *outward*: research → script → TTS → MP3. Language goes *inward*: existing audio → STT → reconciliation → trim. Unifying them behind a common interface would mean a config object full of conditional fields and a pipeline full of `if type == :news` branches. The Tell tool (`lib/tell/`) is standalone for the same reason — it shares vocabulary rendering but nothing else.

**Implication.** When adding a feature, ask which pipeline it belongs to. If it's genuinely cross-cutting (e.g., transcript rendering, upload tracking), factor it as a shared module; do not reach for a common pipeline abstraction.

---

## Cognate filtering is code, not prompt

Vocabulary filtering for cognates (words similar enough to the target-language equivalent that a learner doesn't need them flagged) lives in `VocabularyAnnotator#filter_cognates` — deterministic code using ICU transliteration (`Cyrillic-Latin; Latin-ASCII`) + Levenshtein distance with length-adaptive thresholds.

**Why.** LLM prompts are unreliable for exclusion tasks. "Remove cognates" in a prompt produces inconsistent, language-dependent results and silently drops legitimate entries. The LLM still contributes `similar_translations` (cross-script comparison inputs the code can't derive), but the decision to exclude is deterministic.

**Implication.** When tempted to add "and don't include X" to a prompt, check whether the exclusion can be done post-hoc in code. It almost always can, and it will be more reliable.

---

## Twitter publish is non-fatal by design

`R2Publisher#tweet_new_episodes` (`lib/r2_publisher.rb`) rescues all Twitter errors and logs `"non-fatal"` with the exception class. A failed tweet never aborts a publish. HTTP 402 (X pay-per-use credits at zero) raises `TwitterAgent::CreditsDepleted` after one call instead of being retried.

**Why.** Publish is the critical path — R2 upload, RSS regeneration, LingQ, YouTube. A social-media side effect should not block or roll back the primary artifact shipping. The `UploadTracker` only records the tweet after success, so a failed tweet is naturally retried on the next publish. Non-fatal is not invisible, though: the warning went unseen for 54 days once, because the status board read only the generate logs. `podgen status` now reads the scheduled publishes' stderr (bracketed by `scripts/run.sh` markers) and compares the newest episode with the newest tweeted one, so a silent side effect still trips a WARN.

**Implication.** When adding new side effects to publish, default to non-fatal with tracker-based retry, and give the status board a content-progress check for the side effect's own output (what the listener would see), not just the warning line.

---

## One transcript renderer, driven by a flag

`TranscriptRenderer` is shared by RSS (`RssGenerator`) and site (`SiteGenerator`). RSS passes `vocab: false` (strips vocab, removes bold markers); site uses the default `vocab: true` (linked words + rendered definitions).

**Why.** There is exactly one source of truth for how a transcript turns into HTML. The two consumers differ only in whether vocabulary annotation is *rendered* — not in transcript structure, segmentation, or escaping. A second renderer would drift.

**Implication.** If a consumer needs a third variant, add a flag or a rendering option; do not fork the renderer.

---

## Retry mixins split: `Retryable` vs `HttpRetryable`

Two mixins exist (`lib/retryable.rb`, `lib/http_retryable.rb`) with overlapping-looking APIs (`with_retries`, `with_http_retries`).

**Why.** HTTP failures have their own vocabulary (status codes, `Retry-After`, transient vs permanent by class) that doesn't map cleanly onto a generic retry loop. Forcing one generic `Retryable` to understand HTTP leaks HTTP concerns into every caller; keeping them separate means generic retries stay simple and HTTP retries can be smart about `429`/`503`/network errors.

**Implication.** Use `HttpRetryable` for anything that hits an HTTP endpoint; `Retryable` for non-HTTP flakiness (filesystem, subprocesses, etc.). Don't merge them.

`RemoteImageCache` (`lib/remote_image_cache.rb`, a LingQ `image:` given as a URL) follows the seam pattern: an injected `fetcher` callable in tests, `with_http_retries` by default; it caches into `output/<podcast>/cache/` keyed by a URL digest.

---

## Atomic writes for history and cache

History (`episode_history.rb`), caches (`research_cache.rb`), and upload tracking (`upload_tracker.rb`) all write via temp file + rename.

**Why.** The canonical failure mode is a crash mid-write producing a half-written YAML that poisons all subsequent runs. `File.rename` is atomic on POSIX; temp + rename turns a partial-write failure into a no-op.

**Implication.** Any new persistent state file that the pipeline depends on for correctness should use the same pattern. Import `AtomicWriter` rather than rolling a new one.

---

## Error severity: fatal / retryable / skippable

Every broad `rescue` in `lib/` (no class, `=> e`, `StandardError`, `Exception`, or a modifier `stmt rescue x`) belongs to one of three buckets, annotated at the rescue site:

- **fatal** — the canonical outputs (audio, transcript, feed, site) were not produced. The error escapes to the top-level handler, which logs the exception class and fails the run (a CLI command's handler that reports and exits 1 is fatal too). One stated exception: at publish, `PublishCommand` regenerates the feed first (fatal, unrescued) and the site second; a site-only failure is skippable — `Warning: site/feed regen failed: <Class>: <message>` at every verbosity, the line the status board's publish-warning streak reads — because the feed podcast apps parse is already fresh and the next publish rebuilds the site. `PublisherShared#regenerate!` (the publishers' own regen, reached only when `PublishCommand` did not already regen in-process) still treats feed and site together as skippable-with-warning.
- **retryable** — transient HTTP/API flakiness. Handled by `Retryable`/`HttpRetryable`; never hand-rolled.
- **skippable** — a side effect or enrichment (tweet, LingQ/YouTube upload, vocabulary, cover, subtitle reconciliation). The run continues; tracker-based retry picks it up on the next publish where applicable. A handler that logs names **the exception class** in its warning. Three quiet sub-cases log nothing: a **silent fallback** — a value-parsing guard that substitutes a default (`JSON.parse(body) rescue {}`, `Float(str) rescue nil`, `File.size(f) rescue 0`), annotated `# skippable: silent fallback — <value>`; a **transport guard** — a handler around a best-effort side channel (a client write, a discovery fetch) whose failure is itself the outcome, annotated `# skippable: transport guard — <channel>`; and a handler that hands the exception on instead of logging it (an error result or error callback).

**Why.** A broad `rescue => e` that prints only `e.message` makes a revoked API key (permanent) indistinguishable from a network blip (transient) — the operator sees the same "non-fatal" warning forever. Naming the class in the warning is the cheapest possible signal split. Even cache reads narrow their rescue to the expected classes (`word_stats.rb#load_cache` rescues `Psych::Exception`/`Errno::ENOENT` — corrupt or vanished means "cache miss"; anything else raises). Modifier rescues are limited to cosmetic guards like `logger.phase_end(...) rescue nil`, silent fallbacks and transport guards.

**Implication.** New broad rescue sites must carry a comment that starts with the bucket (`# skippable: …`, `# fatal: …`, `# retryable: …`) on the rescue line, in the comment block directly above it, or as the first comment of a rescue clause's body, and include `e.class` in any warning they log. A unit test parses `lib/` and fails on any broad rescue without one. If you can't say which bucket a rescue is in, it's probably fatal — let it raise.

## Model IDs live in one registry

`lib/claude_models.rb` holds `LINES` (the newest model in each line: opus, sonnet, haiku) and `ROLES` (each call site's role → line). Every Claude call resolves its model through `ClaudeModels.for(:role)`; nothing else in `lib/` may contain a model ID literal (a unit test greps for it).

**Why.** Before P1-0, IDs were hard-coded at eleven sites in eight files with ad-hoc ENV knobs, so a generation bump was a hunt and three sites had no override at all. A manual model switch in 2026-10 then exposed a second hazard: thinking-default models put a thinking block first, so `content.first.text` broke.

**Implication.** A generation bump is a three-line change to `LINES`. Overrides resolve per-role ENV (`CLAUDE_<ROLE>_MODEL`) → per-line ENV (`CLAUDE_OPUS_MODEL` etc.; `CLAUDE_MODEL` aliases the opus line) → default. Read response text through `AnthropicClient.text_of(message)`, never `content.first.text`. The keyed drift test under `test/api` tells you when a line has a newer ID. Effort is per role too: `ClaudeModels.effort(:role)` (nil = omit; `CLAUDE_EFFORT_<ROLE>` overrides) and every call site splats `AnthropicClient.effort_params(role)` (`output_config: {effort:}`; structured callers pass `format:` to merge beside it) — short-output roles run at low, measured by `test/api/test_effort_policy.rb`.

## The owner-action guard asks the real parser

`PodgenCLI.owner_action?` (`lib/cli.rb`) decides whether a `generate` invocation would upload (`--youtube`/`--lingq`) by dry-parsing the argv with generate's own option list (`GenerateOptions.dry_parse`); a token scan is only the fallback when that parse fails. The dry-run exemption for `publish`/`tweet` asks the same way (`PublishOptions.dry_parse`, `TweetOptions.dry_parse`, both over `OptionDryParse`), so `--newest --dry-run` and `--dry` count exactly as the command reads them.

**Why.** The first guard scanned tokens and missed what OptionParser accepts: unique prefixes (`--you`), single-dash completions (`-y`), and flags swallowed as a value-taking option's argument (`--title -- --you`). Four review rounds of patching the scan each found another hole. A guard over a parser's input is only as right as the parser, so it has to ask the parser.

**Implication.** A new generate option that uploads is added to `OWNER_FLAGS` and to the probe table in `test/unit/test_owner_guard.rb` in the same commit. The same rule applies to any future guard over argv or shell text: probe table first, then the real parser; token rules only as the fallback.

## The script reviewer reports; it does not rewrite content

`ScriptReviewer` (`lib/agents/script_reviewer.rb`) reports BLOCKERs, WARNINGs and NITs. Exactly three deterministic checks change the script, each a mechanical fix logged as auto-fixed: a weekday corrected to match its date, stage directions removed, Markdown stripped. Every other change to a script is a rewrite by `ScriptAgent` with the findings attached (at most two retries). Titles are never truncated: the prompt states the ~40-character target, and a longer title is a WARNING.

**Why.** The reviewer once auto-fixed titles over 40 characters by cutting them with an ellipsis. Thirteen episodes shipped with half titles in every feed, on the site and in the ID3 tags before anyone noticed, because the cut happened after the writer had done its job and nothing downstream could object. An editor that silently rewrites output is a second writer with no accountability.

**Implication.** Checks that find a problem send it back to the producer with the finding; they do not patch the artifact. The only exceptions are mechanical, deterministic fixes that cannot lose content (the three above), and each is logged as auto-fixed. A fix that would shorten, rephrase or drop content is never auto-applied.

## A fresh YouTube consent needs a terminal

`YouTubeUploader::LoopbackConsent` (`lib/youtube_uploader.rb`) opens the browser and listens for the OAuth redirect only when stdin and stderr are both terminals; otherwise it raises `YouTubeUploader::NotInteractive` before touching a port, and `authorize!` raises the same error with the token file's path, size and date. `YouTubePublisher` types that error (`:not_authorized`) and stops its loop; the batch upload command ends the YouTube phase after the first pod and exits non-zero.

**Why.** The consent collaborator used to default to "open a browser and wait five minutes" wherever an uploader was built, including the daily launchd batch. With an empty token file that meant four Google sign-in tabs on the owner's desktop every morning, one per podcast, each waiting for a click nobody could give; before that it meant a URL printed into a log nobody read. An authorization that cannot complete must fail once, fast and legibly, not per podcast and not interactively.

**Implication.** Any new scheduled caller of the uploader inherits the refusal for free. A new interactive entry point that should prompt passes `interactive: true` explicitly rather than widening the probe. The token refill itself stays an owner act from a terminal. A failed refresh clears the stored token only when Google rejected the grant; a transport error or 5xx (which googleauth re-raises as `AuthorizationError` with the transport error as its `cause`) propagates with the token intact, so the next run refreshes.

## Episode naming lives in one module

`lib/episode_naming.rb` (`EpisodeNaming`) owns the frozen basename scheme `<podcast>-<YYYY-MM-DD><slot>[-<lang>]`: the day-slot table (`SUFFIXES`, numeric fallback past `z`), `parse`/`basename_for`, the `-<lang>` rule (only a configured code is a language tail; no config = any two-letter tail; the primary is `languages.first`; with `episodes_dir:`, which the render/translate/selector commands pass, an unconfigured tail whose stripped base has its own primary file on disk is still a variant, so a de-configured language is never re-voiced or re-translated as a primary episode), and the history mapping (explicit `basename` wins, else same-day position). The naming helpers (HistoryMaps, EpisodeHistory, EpisodeFiltering, SiteGenerator, StatsCommand) and the scrap/move/render/translate/selector/validator commands call it; a few producers still build `base-code` inline (generate, voice, translate), keyed on the configured primary rather than `"en"`. Feed files follow the same rule through one helper, `PodcastConfig#feed_file_name` (owner ruling): the primary language's feed is always `feed.xml` with the primary code in `<language>`, every other language `feed-<code>.xml`; `rss`, `translate`, the feed validator and the site's feed links all call it.

**Why.** Until P4-9 the rule had eleven copies that disagreed at the edges (Q-44): stats ignored explicit basenames and language variants, `remove_by_date!` was positional only, `scrap`/`move` treated any `-xx` tail as a variant, and the site hard-coded `"en"` as the suffix-less language.

**Implication.** A naming change is a change to one module plus `test/unit/test_characterization_filename_scheme.rb` (the 8-row oracle). Callers that pass no `languages:` get the legacy any-tail rule; pass the configured codes for language attribution (feeds, site, filtering). Deleting and moving deliberately do not: `EpisodeArtifacts` takes every `<base>-*` file, so a language commented out of the config is never left behind by `scrap`/`move`. Stats keys only primary files, so translated mp3s are measured with ffprobe.

## A run says how it went in one line

Every generate (news and language) ends its run log with `RUN-OUTCOME status=ok|warn|error warnings=N errors=M[ first=<text>]` (`lib/run_outcome.rb`, written by `GenerateCommand#finish_run`). `status` is `error` on a non-zero exit, `warn` when the run succeeded with warnings or logged ERROR entries, `ok` otherwise; `first` is the first error on an `error` run (what killed it, not an earlier degradation) and the first warning otherwise, falling back to the other, one line, clipped, always the last field. `podgen status` judges the newest log by that line first; an `ok` outcome or an older log without one falls back to the regex scan.

**Why.** The status board guessed at degradation with `/Warning:|WARNING/` and an `ERROR` on the last line, but the pipelines report trouble in their own words (`⚠ N episode(s) produced (with warnings)`, `  - Language es failed: ...`, a mid-log `ERROR`). A daily translation failure ended its log cleanly and stayed green. The producer knows its outcome; the reader should not reverse-engineer it from prose.

**Implication.** A new degradation joins the run's warnings — the pipeline's `@warnings`, or `Loggable#log_warning` in a library class (a source down, a research or engine failure, a skipped AI review), which the logger counts — not just the log text. Keep the line additive: new fields go before `first=`, and the parser in `RunOutcome` changes in the same commit.
