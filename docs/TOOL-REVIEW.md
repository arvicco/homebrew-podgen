# TOOL-REVIEW.md — Phase 0 module inventory memo (M0-3)

Date: 2026-07-27. Method: four parallel read-only inventory agents over
all of lib/ (≈130 files), synthesized by the orchestrator. Purpose and
design rationale live in README.md / ARCHITECTURE.md — this memo adds
what they don't record: maturity, suspected weak spots, dead code,
duplication, and the pure-logic / contract lists that seed M0-4 and
M0-5. Per Phase 0 rules, nothing below was fixed; every suspected bug
is a decision item awaiting an owner ruling.

## 1. Headline: overall maturity is HIGH

Nearly every module has a dedicated unit test (often thorough:
guidelines_parser 1097 test LOC, podcast_config 1362, site_generator
914). The gate covers 2,942 unit + 48 offline integration runs. The
findings below are the residue, not the norm.

Files with NO dedicated unit test: publisher_shared.rb (transitively
covered), usage_logger.rb, language_names.rb (pure data),
openai_client.rb, and the four network sources bluesky/claude_web/
hn/x (live-API tests only — their parsing logic is untested offline).

## 2. Suspected bugs — decision items (D0-c…D0-n)

Each needs an owner ruling: fix (becomes a Phase 1 packet with a
failing test first), accept as-is, or won't-fix.

- **D0-c** AudioAssembler has TWO `probe_duration` contracts: class
  method returns nil on failure, instance method raises AND caches by
  path forever (a re-voiced file returns the stale duration).
- **D0-d** Transcription::EngineManager threads write shared hashes
  without synchronization (GIL-reliant); also SourceManager (same
  pattern, distinct-keys-per-thread).
- **D0-e** SubtitleReconciler#validate! compares float timestamps with
  strict `==` — an LLM re-serializing `7.7` as `7.700000001` fails
  the whole reconciliation.
- **D0-f** All three STT engines pass `File.open(path, "rb")` to
  HTTParty without closing — one leaked handle per attempt, multiplied
  by retries. Same family: temp paths keyed by `Process.pid` only
  (AudioTrimmer, AtomicWriter, engines) collide across threads in one
  process.
- **D0-g** TimestampPersister.load does no rescue; SubtitleGenerator
  reads the same JSON unguarded — a truncated sidecar raises uncaught
  through generate_srt.
- **D0-h** EpisodeFiltering.matches_language? treats ANY trailing
  `-[a-z]{2}` as a language suffix — an English basename ending in two
  letters after a hyphen is misclassified (feeds site/RSS selection).
- **D0-i** YouTubeUploader.authorize! uses the OOB OAuth flow
  (`urn:ietf:wg:oauth:2.0:oob`) which Google has deprecated — latent
  hard breakage on next re-auth.
- **D0-j** HttpDownloader leaves a partial file on disk when the
  size-limit abort fires mid-stream.
- **D0-k** Voicer deletes TTS temp segments only on the success path —
  a raise inside assemble leaks them.
- **D0-l** TranscriptParser#file? heuristic (`no newline && File.exist?`)
  can misread a single-line transcript body as a file path.
- **D0-m** Retryable off-by-one: `max: 3` yields up to 4 attempts
  (retries incremented before yield). Same in Transcription::BaseEngine;
  its retryable? also substring-matches "429"/"503" in messages.
- **D0-n** ImageRanker class comment (score 2–20, composition_ok veto)
  no longer matches the implementation — stale doc vs code drift.

## 3. Dead / orphaned code — decision items (D0-o)

One ruling can cover the batch (remove in a Phase 1 cleanup packet vs
keep documented):

- agents/transcription_agent.rb — `TranscriptionAgent` alias, zero
  references anywhere.
- transcript_discovery.rb `scrape_episode_page` +
  `extract_transcript_from_html` — production call site commented out;
  test-only.
- transcript_renderer.rb `parse_vocab_lemmas` — no callers.
- script_agent.rb `save_raw_debug` — self-labelled temporary with
  `TODO(2026-06-15)` already expired; still writing debug artifacts.
- tell/glosser.rb `self.correct_readings` — test-only (Engine uses
  merge_phonetic).
- format_helper.rb instance-mixin methods — no `include FormatHelper`
  anywhere.
- transcription engines' `engine_name` — asserted in tests, never
  called in production (EngineManager routes by registry code).
- EngineManager `raise "No engines succeeded"` — unreachable (earlier
  guard raises first).
- translation_agent.rb build_system_prompt glossary tail — a
  `pairs.lstrip.then { }` expression whose result is effectively
  ignored; confused code.
- youtube_downloader.rb `strip_srt_timestamps` — documented
  back-compat shim, test-only.

## 4. Duplication / divergence risks (refactor candidates, owner-approved only)

- **Two YouTube upload paths**: PostPipelineUploads#upload_to_youtube
  vs YouTubePublisher#upload_loop implement the same sequence
  differently — the pipeline path skips retranscription and subtitle
  reconciliation that the publisher does.
- **Reconcile-and-persist reimplemented**: language_pipeline.rb:439
  inlines what SubtitleReconciliationRunner.run wraps (regen_command
  and youtube_publisher use the runner; the pipeline bypasses its
  guards).
- **Filename-scheme knowledge scattered**: the `<podcast>-<date><a–z>`
  suffix convention lives independently in HistoryMaps, EpisodeHistory,
  and stats_command#build_duration_map; the `-<lang>` suffix rule in
  EpisodeFiltering and site_generator; artifact taxonomy in
  EpisodeArtifacts. One documented spec + pinning tests (M0-5) is the
  mitigation; consolidation is a Phase 1 decision.
- **Three word→segment builders**: TimestampPersister,
  ElevenlabsEngine, and GroqEngine each aggregate word timestamps into
  segments with near-identical logic.
- **Name collision**: SubtitleReconciler (segment-preserving) vs
  Transcription::Reconciler (whole-transcript merge) — different jobs,
  confusable names.
- **translate_with_claude / translate_with_openai** ~90% duplicated.
- **CLI help text** duplicates the COMMANDS hash descriptions
  (cli.rb:47–91) — two sources of truth.
- **guidelines_parser** ~15 near-duplicate `parse_*_section`
  list-walking state machines (it is single-responsibility, but the
  duplication is maintenance load).

## 5. Contract inventory — seeds M0-5

The frozen domain (CLAUDE.md rule 4), with owning modules:

| Contract | Owner module(s) | Consumers |
|---|---|---|
| feed.xml shape (RSS 2.0 + itunes/podcast ns, guid = mp3 filename, enclosure url/length/type, itunes:duration mm:ss) | RssGenerator | podcast apps, subscribers |
| Site HTML tree (index + episodes/, relative URL depth rules, versioned CSS) | SiteGenerator + lib/templates/*.erb | browsers |
| Episode basename scheme `<podcast>-<date><a–z>` + `-<lang>` suffix + artifact taxonomy (`_cover*`, `_transcript.md`, `_script.md`, `_script.json`, `_timestamps.json`, `.srt`, `.mp4`, `_concat` exclusion) | HistoryMaps, EpisodeFiltering, EpisodeArtifacts, EpisodeScanner | everything |
| history.yml schema (date/title/topics/urls/duration/timestamp/basename/languages{}) | EpisodeHistory | HistoryMaps → RSS/site, stats |
| uploads.yml schema (platform→group→{basename→id} + legacy migration) | UploadTracker | publishers, uploads_command |
| `_script.json` schema (title/segments[]/sources[]) | ScriptArtifact | voice/translate/render commands |
| `_timestamps.json` schema (version/engine/intro_duration/segments[]) | TimestampPersister | SubtitleGenerator, YouTube path |
| ~/.tell.yml config shape | Tell::Config | tell CLI/web |

## 6. Pure-logic characterization targets — seeds M0-4

Most files have tests; M0-4's job is exact-value pinning of these
deterministic functions specifically (they are the safety net under
any future refactor). Highest value first:

1. SnipInterval — parse/parse_timestamp/keep_segments/merge_intervals
   (cleanest pure module in the codebase).
2. ScriptReviewer — every check_* method, truncate_title,
   normalize_url/urls_match? (richest deterministic surface).
3. GuidelinesParser — parse_language_entry, parse_source_item,
   extract_section, sanitize_css.
4. TranscriptRenderer — parse_vocab_line (monster regex),
   parse_vocab_entries, escape_html/linkify chain (manual HTML
   escaping — verify no XSS gaps while pinning).
5. VocabularyAnnotator — mark_words, cognate?, dedup_by_lemma,
   salvage_truncated_json, split_into_chunks.
6. EpisodeSelector::DateParser — parse/extract_ymd date-form
   defaulting.
7. HistoryMaps.build — basename/suffix derivation (adversarial
   orderings), and EpisodeArtifacts.for_basename prefix-collision
   cases.
8. AnalyticsClient#parse_user_agent (UA classification) + escape.
9. ImageRanker sort-key tuple; EpisodeCoverResolver
   resolve_without_auto branch map.
10. AudioTrimmer — find_speech_end_timestamp, words_match?,
    normalize_word.
11. TextSplitter — split/find_safe_split_point boundary cases;
    TimeValue.parse/parse_duration_seconds.
12. UploadsCommand — run_priority/run_round_robin scheduling with
    injected hooks; parse_pods.
13. TwitterAgent#truncate (t.co 23-char math) + expand_template.
14. Tell — Detector.detect (fully pure), Kana tables, Glosser
    merge_phonetic/split_phonetic/multi_model.
15. Stats/format helpers — build_duration_map, format_*, both
    truncates (and their duplication).
16. Sources — RSSSource.distribute_by_topic/topic_keywords;
    XSource#parse_tweets; ClaudeWebSource#extract_findings (dual-shape
    parsing; currently only live-API-tested).

## 7. Module inventory (condensed)

Grouped; LOC approximate. "OK" = tested, no notable findings beyond
sections above.

**Core pipeline**: episode_source (335, OK; visibility toggling),
source_manager (164, D0-d), guidelines_parser (562, OK),
podcast_config (392, god-object tendencies; inconsistent memoization),
research_cache (54, OK), priority_links (139, YAML+scraping mixed),
script_artifact (77, minimal validation), script_renderer (53, clean),
legacy_script_parser (79, intentionally retained), transcript_discovery
(173, dead scrape path), transcript_parser (114, D0-l),
transcript_renderer (243, complex; §6.4).

**Agents**: script_agent (238, save_raw_debug stale), script_reviewer
(475, richest pure surface), translation_agent (211, duplication),
tts_agent (282, model-knowledge tables scattered), description_agent
(264, repeated API boilerplate), topic_agent (101, OK), cover_agent
(178, deps check blocks pure-math testing), lingq_agent (147, double
rescue), twitter_agent (68, subtle truncate), research_agent (82, OK),
transcription_agent (6, dead).

**Sources**: base_source (52, clean), rss_source (258, dual-mode
class), hn/bluesky/x/claude_web (56–116 each; no offline tests,
blanket per-topic rescues).

**Audio/video/transcription**: audio_assembler (297, D0-c; brittle
loudnorm regex), audio_trimmer (170, temp-path collision),
voicer (55, D0-k), text_splitter (48, OK), snip_interval (143,
cleanest), timestamp_persister (137, D0-g), subtitle_generator (107,
D0-g), subtitle_parser (72, silent JSON swallow),
subtitle_reconciler (83, D0-e), subtitle_reconciliation_runner (50,
status-collapsing rescue), video_builder (37, OK), video_generator
(52, OK), http_downloader (82, D0-j), youtube_downloader (164,
non-fatal rescues), transcription/* (77–134 each, D0-d/D0-f).

**Publish/output**: rss_generator (200, `allocate` renderer hack;
pubDate composition subtle), site_generator (435, long methods;
relative-URL branching), history_maps (68, ordering assumption),
episode_history (151, inconsistent error contract), episode_artifacts
(32, glob over-match risk), episode_scanner (45, loose suffix filter),
episode_filtering (58, D0-h), r2_publisher (192, whole-glob sync),
lingq_publisher (147, OK), youtube_publisher (264, string-matched
rate limits), youtube_uploader (224, D0-i), publisher_shared (38, no
dedicated test), post_pipeline_uploads (133, §4 divergence),
upload_tracker (134, destructive legacy migration on read),
analytics_client (194, weak SQL escape), cover/image chain
(cover_resolver 68 — empty rescue in cleanup; auto_cover_resolver 81;
episode_cover_resolver 143; image_ranker 149 — D0-n; image_searcher
95 — scraped DDG endpoint, inherently fragile).

**CLI**: cli.rb (139, help-text duplication), generate_command (548,
70-line setup_pipeline; dry-run scaffolding in production code),
language_pipeline (781, god-class; ~20 state ivars; inline reconcile
§4), uploads_command (242, subtle drain logic), stats_command (552,
four responsibilities; duplicated truncate), episode_selector (186,
exemplary), remaining commands thin wrappers (OK).

**Tell subsystem** (~3,325 LOC, 20 files): unusually well tested;
engine.rb fire_addons branch tree + thread rescues to nil are the
main hazard; glosser prompt assembly O(n²) compaction; detector fully
pure. engine_pool/history are scoped to web/bin respectively.

**Validators** (12 files, 438 LOC): consistent, low risk; VALIDATORS
array vs check_* delegation can drift; unknown type silently defaults
to news.

**Support**: loggable/logger/retryable (D0-m)/http_retryable
(provider-specific parse_error in generic mixin)/yaml_loader
(type-mismatch silently defaults)/atomic_writer (pid-only temp
name)/format_helper (dead mixin path)/time_value/url_cleaner
(strips generic `ref`/`src`)/usage_logger (no nil guard, no
test)/word_stats (399, mixes 6 concerns)/known_vocabulary (clean)/
vocabulary_annotator (679, largest; §6.5)/language_names (data)/
regen_cache (global state, documented)/anthropic_client (hardcoded
default model in 3 places)/openai_client (thin)/podcast_validator
(dual-list drift risk).

## 8. Proposed Phase 1 seeds (owner to approve/strike)

1. Bug-fix packets for the D0-c…D0-n rulings that come back "fix".
2. Dead-code removal packet (D0-o batch).
3. Consolidation packets (each separate, reviewed): YouTube upload
   path unification; reconcile-runner adoption in language_pipeline;
   filename-scheme module; word→segment builder consolidation.
4. Offline fixture tests for the four network sources (their parsing
   is currently only live-tested).
5. language_pipeline decomposition (staged, characterization-first) —
   the highest-risk refactor; only worth it if the pipeline is
   expected to keep growing.

## Owner sign-off

- [ ] Reviewed; rulings recorded in docs/BACKLOG.md decision items.
