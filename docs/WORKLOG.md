# Worklog

One dense paragraph per completed packet, newest first:
date · packet · commit · notes (what changed, why, evidence, catches).
Incidents get their own entries: what happened, root cause, the
durable fix, the lesson now enforced.

---

2026-10-11 · P1-15, P1-9, P1-7 · 7e18103, e94101a, 9f2994f · P1-15
(orchestrator): a trailing -xx is a language suffix only when the
code is configured; nil/empty list keeps the legacy rule; wired into
episode_basename, RSS (new languages: kwarg), site, and the feed/
history validators; real-data before/after selection identical for
all 7 podcasts. P1-9 (agent): normalize_url scheme case-insensitive;
tweet truncate no dangling newline; ImageRanker comment matches code
+ sort tuple pinned; duplicate StatsCommand#truncate removed (gate
warning gone); interactive length-check exclusion exits 0 — the
non-interactive abort deliberately stays 1. P1-7 (agent): Mutex on
EngineManager/SourceManager result writes with concurrency
characterization tests; dead raise removed; retry contract documented
(max = retries after first attempt, unchanged); retryable? by status
code when available, word-boundary message match otherwise ("error
id 14290" no longer retries). Gate 3119+50 green after each
cherry-pick. Two agents ran concurrently in worktrees without
conflict; orchestrator reviewed every lib diff before landing.

2026-10-11 · P1-5 (Q-03, Q-04) · 6d4e859 · SubtitleReconciler#validate!
accepts timestamp drift within 0.01 s (count mismatch still fatal);
the three STT engines open the audio file once and close it in ensure
around the POST — one fd per attempt no longer leaks across retries;
AudioTrimmer, Groq downsample and AtomicWriter temp names carry a
SecureRandom suffix so threads in one process cannot collide; the
trimmer test teardown globs the new names. Worktree agent (sonnet):
red proven per item (mismatch error, leaked-handle counts, identical
paths, ENOENT on shared tmp), diff reviewed and cherry-picked. Gate
3107+50 green. Agent catch: the tool sandbox in worktrees refuses
compound git/bundle commands with shell variables — plain commands
only.

2026-10-11 · P1-6 (Q-08, Q-09) · c6c0be3 · HttpDownloader#write_body streams
to <dest>.part.<pid>, renames on success, deletes the temp in ensure —
a size-cap abort leaves nothing at the destination. Voicer deletes
its TTS segment files in ensure around the assembly step, so a raise
in AudioAssembler#assemble no longer strands them (error still
propagates). Worktree agent (sonnet), red-then-green, diff reviewed
and cherry-picked. Gate 3099+50 green. Note for a later look: the
.part temp is pid-keyed (same collision class as Q-04b, harmless
today — one download per path per process). Tooling catch: in agent
worktrees `rake gate` stops at lint with offenses in bin/podgen and
bin/tell that the primary checkout and CI do not report —
path-relative .standard_todo.yml matching; agents run the tiers
separately.

2026-10-11 · P1-3 · 52fef3b · Test-hygiene batch via a worktree
implementation agent (sonnet), diff reviewed and cherry-picked by the
orchestrator. Four of five items changed: TWITTER_* ENV restore in
test_twitter_agent (prefix-guessing → save/restore in ensure);
AudioTrimmer pid-named tmp litter removed in teardown; explicit
pathname require in the drift test; CI concurrency group
(ci-<ref>, cancel-in-progress). PODGEN_ROOT item: the agent verified
both files already save/restore correctly and changed nothing — the
plan's premise was stale. Seeds 1/2/3 green; gate green on phase-1.
Catches worth keeping: agent worktrees start from the default branch,
so agents must fast-forward to phase-1 first; worktrees have no
vendor/bundle (BUNDLE_PATH to the main checkout works); TESTOPTS needs
--seed=N; 18 older pid-named trimmer files from past sessions remain in
/var/folders (not deleted by the agent — owner's tmp).

2026-10-11 · P1-4 (Q-05, Q-01) · aff5261 · One guarded sidecar load:
TimestampPersister.load raises CorruptSidecarError (StandardError
subclass, names the file) and SubtitleGenerator.generate_srt now goes
through it instead of its own JSON.parse. AudioAssembler#probe_duration
memo keyed by (path, mtime, size) so a re-voiced/trimmed file is
re-probed; the class/instance contract split (nil vs raise) kept on
purpose and documented. Red: raw ParserError from both consumers; a
rewritten 3s tone served as 1s from the memo. Gate 3097+50 green.
Executed by the orchestrator while the P1-3 worktree agent ran — no
file overlap.

2026-10-11 · P1-1 · dca69d8 · Permission audit over 21 invocation paths
(.docs/P1-1-permission-matrix.md). Finding: the deny list anchored on
`bin/podgen <cmd>` — bundle exec / ruby / --quiet / absolute path /
bash -c / cd && / wrapper scripts / launchctl start all slipped past
(probe reached the publish command via bundle exec); the box's local
settings also blanket-allow bin/podgen:*, bundle exec:*, ruby:*, git:*.
Fix: leading-`*` deny rules (deny is evaluated first in every scope and
inside split compound commands/subshells per the docs) + an in-process
guard in lib/cli.rb (CLAUDECODE=1 → refuse owner actions and generate
--youtube/--lingq, exit 2, unless --dry-run or PODGEN_OWNER=1). Allow
`bundle exec ruby*` narrowed to -I/test forms. Catches: settings.json
is NOT hot-reloaded (probe after edit still ran → V1 at next session
start); an unstubbed red test run executed real owner commands and hung
— tests now stub the command class; test_helper clears CLAUDECODE so
the suite is session-independent. Gate 3094+50; live guard probes
green. Owner note (not a packet): prune the local settings allows.

2026-10-11 · P1-12 (Q-24) · 95893e5 · Enrich prompt now lists the exact
English key names it requests (dynamic: pronunciation /
similar_translations only when asked, which an existing test pins)
and forbids translating them; a ParserError on a non-truncated enrich
response falls through to salvage_truncated_json so entries before
the malformed object survive, with one WARNING naming the count.
Ruled no retry (cost; cause addressed). Red: the exact incident error
"expected object key, got 'лемма:'" and the missing prompt line.
Gate 3090+50 green; CI green. Outcome at the listener surface: the
next bajke episode's transcript must carry a vocabulary section even
if the model slips again — verified at the next owner bajke generate.

2026-10-11 · P1-0 (code) · 869f84e, 05b3e93, +drift test · One model
registry: lib/claude_models.rb LINES (newest per line) + ROLES (13 call
sites → line); resolution per-role ENV → per-line ENV → default;
CLAUDE_MODEL now aliases the opus line (R1-a) so it reaches the
reviewer too (previously on its own key only) and no longer steers
Tell translation (own role, sonnet line). AnthropicClient.text_of
replaced all 11 `content.first.text` reads (thinking-default models
put a thinking block first). Step 2 landed at the old IDs with zero
behavior change (gate green), step 3 was the 3-line bump to
opus-5-5 / sonnet-5-5 / haiku-5-5 — what the Models API serves as
newest (created 09-21, 09-28, 10-07), verified by the new keyed drift
test (green live). Catches: two Tell-config passthrough tests were
over-pinned to the alias and had to go back to literals; the test
helper loads .env, so registry tests isolate every CLAUDE_* key.
Operational fact worth knowing: the launchd job runs scripts/run.sh
from THIS checkout, so the 16:30 news run exercises whatever phase-1
has at that moment — it is the outcome check for this packet, read
at the next wakeup. Open from the bump (Q-28 baseline): small-cap
calls (description 256, language-detect 30 tokens) on thinking-
default sonnet/haiku lines may truncate; the scheduled run's
description step is the first evidence.

2026-10-11 · R1-a…R1-i ruled · (docs commit) · Owner ruling: decision
items are for PRINCIPAL questions only (frozen domain, phase scope,
spend policy, owner data, listener-visible behavior); implementation-
level choices are the orchestrator's job. All nine open items ruled
at orchestrator level and recorded in their packets: CLAUDE_MODEL
aliases the opus line and Tell translation gets its own key (P1-0);
default effort kept, baseline measured in P1-0, policy queued as
Q-28; drift check in; gate lint = new files + touch-to-migrate
(P1-3); exclusion exits 0 on both paths and the duplicate truncate
goes (P1-9); language-suffix fix scheduled as P1-15 on evidence that
only -es/-it/-jp exist on disk; YouTube OAuth loopback scheduled as
P1-16 with the re-auth in the gate runbook; dead-code batch stays
KEPT until a packet touches each file; six pinned quirks accepted.
Registry empty.

2026-10-11 · INCIDENT 2026-10-08 (recorded late) · no commit · The
scheduled fulgur_news run (16:46) had no DNS for ~2.5 h: every host
failed with getaddrinfo; TopicAgent fell back to queue.yml, all four
research sources and the ScriptAgent exhausted retries, exit 1 at
19:19. No episode that day. Root cause: local name resolution lost
(same signature 2026-09-17 and 2026-09-19, all mid-afternoon;
machine/network side, not code). Why it hurt: SDK-internal retries ×
with_retries × per-source retries compounded into hours, and the
Telegram failure alert rode the same dead network, so the owner
learned of it from the missing episode. Durable fix: queued as Q-26
(connectivity preflight + bounded retry budget) and Q-27 (scheduled
content-progress check + status surface; also covers the Twitter
"credits depleted" warning repeating daily since 2026-09-18 unseen).
Lesson enforced: incidents get a worklog entry the day they are
diagnosed, and every "worth a packet later" becomes a Q item at once.

2026-10-10 · P1-11 (Q-25) · bdefdc8 · Incident 2026-10-09: fulgur_news
died after 8 ScriptAgent attempts, all "SDK parsing failed: unexpected
end of input". Root cause: CLAUDE_MODEL switched by hand to a
thinking-default model (opus-5-5); thinking tokens count against
max_tokens, so the 8192 cap — already within reach of 4.6k–7.8k
historical script outputs — truncated the structured JSON, and
with_retries re-issued the identical request 3× per review round
(two rounds, ~11 min each, deterministic failure). Fix: max_tokens
16384 in ScriptAgent and TranslationAgent (same cap, same exposure);
require_parsed_output! raises TruncatedOutputError on a max_tokens
stop with unusable output — a sibling of StructuredOutputError, not a
subclass, so existing `on:` lists let it propagate after ONE call with
a message naming the cap. 7 tests (helper error split, max_tokens pin
and single-call pin for both agents) red-then-green; gate 3075+50;
CI green. Lesson: this is P1-0 hazard H3 arriving early — thinking
budget per role is decision R1-b; model defaults move to the registry
in P1-0 (next). Outcome check at the owner's surface pending (news
generate on the current model → end_turn on attempt 1).

2026-09-02 · GATE 0 CLOSED · owner merged PR #1 (merge 4298988) —
the gate-closing event. Phase 0 delivered: dev-loop instantiation,
rake gate + CI, source registry + drift test + rake health, freshness
invariant, QuickTime ask-trim, frozen-domain oracles, 76-test
characterization net, README refresh; CRPR 1 blocker fixed, APPROVED.
Branch phase-1 opened from merged master. Owner directive at close:
re-run code review on merged master BEFORE Phase 1 planning; plan
ships as .docs/p01-plan.md for sign-off.

2026-09-01 · CRPR fixes · (this commit) · Phase-0 CRPR verdict:
1 BLOCKER, 0 warnings, 7 nits. BLOCKER fixed: the settings.json
allow-glob `git push origin phase-*` also matched refspec pushes to
master (`phase-0:master`) and `--force` variants — added
match-anywhere deny patterns (deny wins) closing golden-rule-3
enforcement; also dropped the six dead env-PATH allow entries.
Nits fixed same-commit: CLAUDE.md gate comment now mentions lint;
README drift-scanner claim softened (literal URLs only); misnamed
registry test renamed. Deferred nits queued: Q-22 freshness opt-out
for concluded podcasts, Q-23 QT front-document targeting. Gate
3068+50 green; re-review requested.

2026-09-01 · P0-4 · (this commit) · Characterization audit + safety
net. Read-only audit mapped the memo's 67 pure-logic targets: 37
directly tested, 9 via thin orchestrators (accepted), 21 gaps. A
worktree implementation agent wrote 76 exact-value tests across 14
existing files (t.co truncation math, duration parsing, timestamp
parsing, section/language/source guideline parsing, date-form
defaulting, split-point priorities incl. UTF-8 fallback, interval
merging, topic bucketing, round-robin scheduling behavior, vocab-line
regex, URL normalization, multi_model fan-out, live truncate).
Orchestrator reviewed the diff (tests-only, no weak assertions),
applied, gate 3068+50 green, worktree removed. Zero production
diffs. 8 pinned oddities recorded as unruled queue candidates
Q-14…Q-21 — notable: priority-URL check misses uppercase-scheme
URLs; topics like "AI" can never claim findings; TTS comma-split
chunks start with ", ".

2026-09-01 · P0-6 · (this commit) · README honesty pass: --ask-trim
now documented as the QuickTime preview flow (flag table +
interactive-trimming section), stale exclude-key `[e]` corrected to
the real `e[x]clude`, new Development section covering rake
gate/test/health, the source-registry drift rule, and the freshness
OLD flag. Private-config detail (dead zverinice feed) deliberately
kept OUT of the public README per the internal-comms ruling. Owner
acceptance rides on Gate 0.

2026-09-01 · P0-5 · (this commit) · Frozen-domain pinning tests
(test/unit/test_frozen_contracts.rb): history.yml entry key set (incl.
languages sub-schema), uploads.yml platform→group→{basename→id}
nesting, *_timestamps.json schema (version 1, segment keys, intro
offset, reconciled additivity), HistoryMaps basename suffix scheme
(''+a..z, explicit basename wins), and the full RSS item shape —
element order, m:ss duration, enclosure url/length/type, guid == bare
mp3 filename, pubDate composition, channel element set. Oracle proven
red on a seeded extra item element, green on HEAD. Gate 2963+50.

2026-09-01 · rulings batch · (this commit) · Owner ruled the three
standing registry items. R0-p: stray worktree commit 6dd5ba8
discarded (worktree + branch removed), merged
refactor/dry-and-test-coverage pruned local + origin — repo is down
to master + phase-0 everywhere. R0-o: dead-code batch KEPT documented,
periodic-review item Q-13. R0-c…R0-n: formulated as self-contained
queue items Q-01…Q-12 in the new work queue (each with problem,
first-failing-test sketch, acceptance, tier suggestion; fix packets
get cut from the queue when scheduled). Queue initially committed to
tracked docs/ in error; owner ruled same day that dev queue + phase
planning are internal (.docs/) and only executed work reaches the
worklog — relocated to .docs/WORK-QUEUE.md. Registry now holds only
the formal P0-3 sign-off. P00-7 owner-confirmed in real use, closed.

2026-08-31 · P00-7 · (this commit) · Preview re-wired Quick Look →
QuickTime Player after the owner's real-run check on P00-6 found
qlmanage takes no focus and can't autoplay (headless; keystroke
injection would need Accessibility). QT does both natively: `open -a`
launches frontmost with the file (avoiding the AppleScript -600
tell-before-registered race the owner hit in the first trial), a
backgrounded osascript waits for the document and plays it, and an
is-running-guarded close script shuts the document after the prompts
(incl. exclude) without relaunching a quit QT. Owner trialled the
corrected script on a real episode before any code changed. TDD: 3 QT
specs errored first, then green; gate 2958+50; close script verified
against the live trial window. Third player iteration — Music
(pollution) → ffplay (rejected) → Quick Look (no focus/autoplay) →
QT; requirements now fully pinned in tests.

2026-08-30 · P00-6 · (this commit) · ask-trim preview via Quick Look
(R0-r option B, owner-trialled on a real episode and approved before
any code changed — lesson from P00-5 applied). `open`→Music replaced
by background `qlmanage -p`: positional scrubbing + min:sec readout,
zero library imports, prompts live while the preview is open, TERM on
prompt completion and on exclude (ensure block). TDD: 3 tests red
(NoMethodError / no spawn) then green; existing ask_trim
characterization tests repointed from the :system stub to the new
:start_preview seam. Gate 2958+50 green. Music pollution class closed:
nothing is imported anymore, so cleanup options A/D unnecessary.

2026-08-30 · P00-5 REVERTED · (this commit) · ffplay ask-trim preview
(5bfca6e) rejected by owner within hours: ffplay's fixed-step seeking
and bare window are not usable for the trial-and-error hunt for
cut-off points — Apple Music's transport is the requirement, the
pollution is the bug. Lesson: the R0-q proposal optimized what I
could measure (no library imports, seconds readout) over the owner's
actual workflow (fast interactive scrubbing); the owner check in the
acceptance criteria fired exactly as designed. `open`→Music restored;
mitigation research filed as R0-r (options: post-preview AppleScript
auto-cleanup inside --ask-trim; Quick Look zero-import preview;
periodic sweep). ttt.mp3 deletion stands (approved separately).

2026-08-25 · P00-4 · (this commit) · Freshness invariant:
Validators::FreshnessValidator (newest content date vs wall clock,
cadence = median history gap, OLD warning past 2× median) wired into
PodcastValidator (array + check_freshness). TDD: 7 unit tests failed
for the right reason first. The new check immediately caught the
test_stats_validate "clean podcast" fixture rotting (hard-coded
2026-01 dates) — fixture moved to relative dates. Outcome check on
real data: lahko_noc flags OLD (newest 2026-03-21, 157d, daily
cadence); bajke/basnie/cuentos/fiabe/fulgur_news validate fresh;
ruby_world correctly reports cannot-infer-cadence. Gate green.

2026-08-25 · P00-3 · 1c6f87d · Source registry: 14 hard-coded service
endpoints registered with probe URLs + expectations; drift test in
the offline gate (red on seeded unregistered host, green on HEAD);
IGNORED_HOSTS allowlist for namespace/display URLs; rake health
owner-run probe — 14/14 OK live (elevenlabs probe URL corrected
after first run). Per-podcast RSS feeds ruled out of registry scope
(config, not hard-coded).

2026-08-25 · P00-1 + P00-2 · (this commit) · Phase 00 opened per
owner ruling (conventions before Phase 0 continues). P00-1: gitignored
.docs/ workspace created; TOOL-REVIEW.md relocated there;
.docs/DECISIONS.md registry seeded (R0-p stray-worktree salvage, R0-o,
R0-c…R0-n, P0-3 sign-off — newest first, removed when ruled); dev-loop
plugin skill+templates updated in its own repo (commit 34a4994) to
encode the convention. P00-2: CLAUDE.md verification discipline
extended to the skill's six items (specific asks; commit
owner-session data); DEV-LOOP.md §4 gains the ring-for-owner alarm
step. P0-3 status normalized to blocked: decision-item. Docs-only in
podgen; gate green.

2026-07-27 · P0-3 (memo drafted) · (this commit) · Full-lib inventory
via four parallel read-only agents (~130 files), synthesized into
docs/TOOL-REVIEW.md: 12 suspected-bug decision items (R0-c…R0-n), a
10-item dead-code batch (R0-o), 8 duplication/divergence risks, the
frozen-contract inventory seeding P0-5, and a ranked 16-entry
pure-logic list seeding P0-4. Coverage headline: nearly every module
already has a dedicated unit test; gaps are publisher_shared,
usage_logger, openai_client, language_names, and the four network
sources (live-API tests only). Packet stays in-progress until owner
sign-off per acceptance.

2026-07-27 · P0-2 · (this commit) · Gate wired into CI: rake gate now
also runs standardrb (was CI-only, so local gate and CI agree — it
immediately caught a quote-style violation in the gate task itself);
ci.yml triggers on phase-* pushes and collapses its three test steps
into one `bundle exec rake gate` step. COVERAGE=1 scope widened from
unit-only to the whole gate (simplecov now sees offline integration
too). Evidence: gate green locally (305 files syntax-OK, lint clean,
2942+48 runs); CI on pushed head checked below.

2026-07-27 · P0-1 · (this commit) · Dev-loop migration: instantiated
CLAUDE.md (arbot-style golden rules; CRPR retained as pre-PR review;
git model moved to phase branches + owner-merged PRs per R0-a),
docs/DEV-LOOP.md, docs/BACKLOG.md (full brownfield Phase 0 per owner
ruling), docs/WORKLOG.md; added `rake gate` (syntax check over
lib/bin/test + test:unit + test:integration_offline). Evidence: gate
run green locally before commit.
