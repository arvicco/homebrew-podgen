# Work Queue — podgen

Ruled-but-unscheduled work items (owner ruling 2026-09-01: the M0-3
inventory's suspected bugs become queue items rather than immediate
fixes). Q-xx items are self-contained; when one is scheduled, it is
cut into a backlog packet (M<phase>-<n>) and marked `scheduled: M…`
here. Every fix packet starts with a failing test per CLAUDE.md
workflow. Source analysis: .docs/TOOL-REVIEW.md §2 (gitignored,
regenerable).

Format: `## Q-nn · title  [from: D0-x] [tier: suggestion] [status: queued]`

---

## Q-01 · AudioAssembler dual probe_duration contracts + stale cache  [from: D0-c] [tier: implementation] [status: queued]
Problem: class method returns nil on ffprobe failure; instance method
raises AND memoizes per path with no invalidation — a re-voiced or
trimmed file returns the previous duration.
First test: probe a path, rewrite the file, probe again — expect the
new duration (fails today). Second: pin one contract for both arities
or document the divergence.
Acceptance: cache invalidates on mtime/size change (or is removed);
failure behavior consistent; callers audited (rss_generator fallback
chain, audio_trimmer, stats).

## Q-02 · Unsynchronized thread writes in EngineManager + SourceManager  [from: D0-d] [tier: implementation] [status: queued]
Problem: parallel engine/source threads mutate shared result hashes
relying on the GIL; also EngineManager has an unreachable
"No engines succeeded" raise (earlier guard fires first).
First test: characterization of merge behavior, then wrap writes in a
Mutex (or per-thread results merged after join).
Acceptance: no shared-state mutation from threads without a lock;
dead raise removed or reachable; existing multi-engine tests green.

## Q-03 · SubtitleReconciler strict float == on timestamps  [from: D0-e] [tier: implementation] [status: queued]
Problem: validate! compares LLM-returned start/end with `==`; a
re-serialized `7.7` → `7.700000001` fails the entire reconciliation.
First test: reconcile fixture where returned timestamps differ by
1e-6 — expect acceptance within epsilon (fails today with
ReconciliationError).
Acceptance: epsilon comparison (e.g. 0.01s); count mismatch still
hard-fails.

## Q-04 · STT engines leak file handles; pid-only temp paths collide  [from: D0-f] [tier: implementation] [status: queued]
Problem: elevenlabs/groq/openai engines pass File.open(path, "rb") to
HTTParty without closing (one fd per attempt × retries). Temp paths
keyed by Process.pid only (AudioTrimmer, AtomicWriter, engines,
tts_agent) collide across threads in one process.
First test: engine call closes its file handle (fd count stable
across stubbed retries); temp path helper uniqueness under threads.
Acceptance: handles closed via ensure/block form; temp names include
thread id or SecureRandom; AtomicWriter temp unique per writer.

## Q-05 · Unguarded JSON reads of *_timestamps.json  [from: D0-g] [tier: implementation] [status: queued]
Problem: TimestampPersister.load and SubtitleGenerator.generate_srt
parse the sidecar with no rescue — a truncated/corrupt file raises
JSON::ParserError uncaught through srt generation.
First test: corrupt fixture sidecar → expect a clean, named error (or
nil-with-warning contract) instead of raw ParserError.
Acceptance: one guarded load path shared by both consumers; runner
statuses preserved.

## Q-06 · matches_language? misclassifies `-xx` basename endings  [from: D0-h] [tier: implementation] [status: queued]
Problem: EpisodeFiltering treats ANY trailing `-[a-z]{2}` as a
language suffix — an English basename legitimately ending in two
letters after a hyphen is excluded from English feed/site selection.
First test: basename like `pod-2026-01-01-ai.mp3` (title-derived
suffix) classified as English when no `ai` language is configured.
Acceptance: suffix check validated against the podcast's configured
language set; frozen-domain caution — output selection changes need
the pinning tests (M0-5) in place first.

## Q-07 · YouTube OAuth uses deprecated OOB flow  [from: D0-i] [tier: top — auth flow redesign, owner-visible] [status: queued]
Problem: youtube_uploader.rb authorize! uses urn:ietf:wg:oauth:2.0:oob,
which Google has shut off for new clients — next re-auth on a fresh
token likely hard-fails; also interactive $stdin.gets inside the
library.
First step: spike loopback-redirect flow (localhost listener), then
test with mocked token exchange.
Acceptance: re-auth works on a clean ~/.config/podgen; existing
token refresh path untouched; interactive prompt moved to CLI layer.

## Q-08 · HttpDownloader leaves partial file on size-limit abort  [from: D0-j] [tier: implementation] [status: queued]
Problem: mid-stream size-cap raise leaves a truncated file at the
destination path; a retry or naive caller may treat it as complete.
First test: stream exceeding the cap → destination absent (or .part)
after the raise.
Acceptance: download writes to temp + rename (AtomicWriter pattern);
partials cleaned in ensure.

## Q-09 · Voicer leaks TTS temp segments on assemble failure  [from: D0-k] [tier: implementation] [status: queued]
Problem: intermediate audio paths deleted only on success; a raise in
AudioAssembler#assemble strands the segment files in tmpdir.
First test: assembler stub raises → segment files removed anyway.
Acceptance: cleanup in ensure; success path unchanged.

## Q-10 · TranscriptParser#file? heuristic ambiguity  [from: D0-l] [tier: implementation] [status: queued]
Problem: `!text.include?("\n") && File.exist?(text)` — a single-line
transcript body that happens to match an existing path is read as a
file.
First test: parse(single-line string equal to an existing fixture
path) → treated as text.
Acceptance: explicit path:/text: keyword API or a stricter heuristic;
all call sites audited (site_generator, word_stats, reconciliation
runner).

## Q-11 · Retryable off-by-one + substring-matched retry codes  [from: D0-m] [tier: implementation] [status: queued]
Problem: `retries += 1` before yield makes max:3 mean 4 attempts
(same in Transcription::BaseEngine); BaseEngine#retryable? substring-
matches "429"/"503" anywhere in the message.
First test: with_retries(max: 3) counts exactly 3 attempts (pin
current behavior first — callers may depend on 4); retryable? false
for a message merely containing "429" in unrelated text.
Acceptance: documented, consistent attempt semantics across both
mixins; status-code-based retry detection where a response is
available.

## Q-12 · ImageRanker stale doc-vs-code drift  [from: D0-n] [tier: implementation — doc fix] [status: queued]
Problem: class comment describes score range 2–20 and a
composition_ok veto that the code no longer implements (veto is
has_overlay_watermark only).
Acceptance: comment matches implementation; sort-key tuple pinned by
a unit test while touching it.

## Q-13 · Dead/orphaned code batch — periodic review  [from: D0-o] [tier: top — review, no code change] [status: queued — owner ruling 2026-09-01: KEEP documented]
Ruling: the 10 items (TranscriptionAgent alias, commented-out scrape
path, parse_vocab_lemmas, expired save_raw_debug TODO,
Glosser.correct_readings, FormatHelper mixin path, engines'
engine_name, unreachable EngineManager raise, glossary-tail
expression, strip_srt_timestamps shim) STAY in the code, documented
here and in .docs/TOOL-REVIEW.md §3. Revisit at a future review
(e.g. a phase gate); each item gets its own keep/remove ruling then.
Acceptance (when scheduled): per-item disposition recorded; removals,
if any, land as one reviewed cleanup packet.
