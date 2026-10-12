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

`R2Publisher#tweet_new_episodes` (`lib/r2_publisher.rb`) rescues all Twitter errors and logs `"non-fatal"`. A failed tweet never aborts a publish.

**Why.** Publish is the critical path — R2 upload, RSS regeneration, LingQ, YouTube. A social-media side effect should not block or roll back the primary artifact shipping. The `UploadTracker` only records the tweet after success, so a failed tweet is naturally retried on the next publish.

**Implication.** When adding new side effects to publish, default to non-fatal with tracker-based retry. Reserve fatal errors for steps that produce the canonical outputs (audio, feed, site).

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

---

## Atomic writes for history and cache

History (`episode_history.rb`), caches (`research_cache.rb`), and upload tracking (`upload_tracker.rb`) all write via temp file + rename.

**Why.** The canonical failure mode is a crash mid-write producing a half-written YAML that poisons all subsequent runs. `File.rename` is atomic on POSIX; temp + rename turns a partial-write failure into a no-op.

**Implication.** Any new persistent state file that the pipeline depends on for correctness should use the same pattern. Import `AtomicWriter` rather than rolling a new one.

---

## Error severity: fatal / retryable / skippable

Every `rescue` in the pipelines and publishers belongs to one of three buckets, annotated at the rescue site:

- **fatal** — the canonical outputs (audio, transcript, feed, site) were not produced. The error escapes to the top-level handler, which logs the exception class and fails the run.
- **retryable** — transient HTTP/API flakiness. Handled by `Retryable`/`HttpRetryable`; never hand-rolled.
- **skippable** — a side effect or enrichment (tweet, LingQ/YouTube upload, vocabulary, cover, subtitle reconciliation). Logged as a warning **including the exception class** and the run continues; tracker-based retry picks it up on the next publish where applicable.

**Why.** A broad `rescue => e` that prints only `e.message` makes a revoked API key (permanent) indistinguishable from a network blip (transient) — the operator sees the same "non-fatal" warning forever. Naming the class in the warning is the cheapest possible signal split. Even cache reads narrow their rescue to the expected classes (`word_stats.rb#load_cache` rescues `Psych::Exception`/`Errno::ENOENT` — corrupt or vanished means "cache miss"; anything else raises). The only tolerated bare modifier rescues are cosmetic guards like `logger.phase_end(...) rescue nil`.

**Implication.** New rescue sites must name their bucket in a trailing comment and include `e.class` in any warning they log. If you can't say which bucket a rescue is in, it's probably fatal — let it raise.

## Model IDs live in one registry

`lib/claude_models.rb` holds `LINES` (the newest model in each line: opus, sonnet, haiku) and `ROLES` (each call site's role → line). Every Claude call resolves its model through `ClaudeModels.for(:role)`; nothing else in `lib/` may contain a model ID literal (a unit test greps for it).

**Why.** Before P1-0, IDs were hard-coded at eleven sites in eight files with ad-hoc ENV knobs, so a generation bump was a hunt and three sites had no override at all. A manual model switch in 2026-10 then exposed a second hazard: thinking-default models put a thinking block first, so `content.first.text` broke.

**Implication.** A generation bump is a three-line change to `LINES`. Overrides resolve per-role ENV (`CLAUDE_<ROLE>_MODEL`) → per-line ENV (`CLAUDE_OPUS_MODEL` etc.; `CLAUDE_MODEL` aliases the opus line) → default. Read response text through `AnthropicClient.text_of(message)`, never `content.first.text`. The keyed drift test under `test/api` tells you when a line has a newer ID.

## Episode naming lives in one module

`lib/episode_naming.rb` (`EpisodeNaming`) owns the frozen basename scheme `<podcast>-<YYYY-MM-DD><slot>[-<lang>]`: the day-slot table (`SUFFIXES`, numeric fallback past `z`), `parse`/`basename_for`, the `-<lang>` rule (only a configured code is a language tail; no config = any two-letter tail; the primary is `languages.first`), and the history mapping (explicit `basename` wins, else same-day position). HistoryMaps, StatsCommand, EpisodeHistory, EpisodeFiltering, SiteGenerator, PodcastConfig, EpisodeArtifacts and the scrap/move/render/translate/selector/validator code all call it.

**Why.** Until P4-9 the rule had eleven copies that disagreed at the edges (Q-44): stats ignored explicit basenames and language variants, `remove_by_date!` was positional only, `scrap`/`move` treated any `-xx` tail as a variant, and the site hard-coded `"en"` as the suffix-less language.

**Implication.** A naming change is a change to one module plus `test/unit/test_characterization_filename_scheme.rb` (the 8-row oracle). Callers that pass no `languages:` get the legacy any-tail rule; pass the configured codes wherever a config is at hand.
