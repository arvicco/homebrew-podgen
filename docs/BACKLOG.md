# Backlog — podgen

Flat, human-editable packets; the loop's entire coordination state.
Statuses: ready → in-progress → done | blocked: <reason>.
Packet IDs: P<phase>-<n>. Decision items: R<phase>-<letter> — OPEN
items live in .docs/DECISIONS.md (gitignored, newest first, removed
when ruled); the ruling is recorded inline in the affected packet.
Research/planning docs, the work queue (.docs/WORK-QUEUE.md, Q-xx
items — packets are cut from it when scheduled), and phase plans
live in gitignored .docs/ — internal communication never lands in
the public repo; work reaches the tracked worklog only once
executed. The executing session updates its own packet's status and
appends one worklog paragraph per completed packet.

Packet format:

## P0-1 · <title>  [tier: <model-or-role>] [status: ready] [deps: --]
Goal: <one testable outcome>
Acceptance: <the machine-checkable oracle: which tests/checks prove it>

---

## Phase 00 — conventions & loop infrastructure (owner ruling 2026-08-25:
land these before the rest of Phase 0)

## P00-1 · .docs workspace + decisions registry  [tier: top] [status: done] [deps: --]
Goal: gitignored .docs/ holding research/planning docs; open owner
      decisions in .docs/DECISIONS.md (newest first, removed when
      ruled); TOOL-REVIEW.md relocated; dev-loop plugin templates
      updated to encode the convention.
Acceptance: .docs/ ignored by git; DECISIONS.md seeded with all open
      items; no tracked process artifacts beyond BACKLOG/WORKLOG.
Done: 2026-08-25.

## P00-2 · Verification-discipline + alarm doc sync  [tier: implementation] [status: done] [deps: --]
Goal: CLAUDE.md gains discipline items 5 (specific verification asks)
      and 6 (commit owner-session data immediately); DEV-LOOP.md §4
      gains the ring-for-owner alarm step.
Acceptance: both docs match the dev-loop skill's six-item discipline;
      gate green (docs-only).
Done: 2026-08-25.

## P00-3 · Source registry  [tier: top — first-of-family seam design] [status: done] [deps: --]
Goal: lib/source_registry.rb registering every hard-coded external
      endpoint (name, probe URL, expected shape); a gate-tier drift
      test that scans lib/ for known HTTP hosts and fails on any
      endpoint missing from the registry; an owner-run network probe
      task (`podgen test health` or rake task) checking each probe
      URL + shape.
Acceptance: drift test red on a seeded unregistered endpoint, green
      on HEAD; registry covers all 14 hard-coded service hosts
      (Anthropic/OpenAI/ElevenLabs/Groq/GoogleTTS/YouTube/LingQ/
      HN-Algolia/Bluesky/socialdata/Exa/Telegram/Cloudflare/DDG);
      gate green; probe task green once. Note: per-podcast RSS feeds
      (RTVSLO etc.) are guidelines.md config, not hard-coded — covered
      by podgen validate + P00-4, not the registry.
Done: 2026-08-25. `rake health` 14/14 OK (elevenlabs probe URL fixed
      after first live run).

## P00-4 · Content-progress (freshness) invariant  [tier: implementation] [status: done] [deps: --]
Goal: lib/validators/freshness_validator.rb wired into podgen
      validate: newest episode date in the generated feed vs wall
      clock against the podcast's cadence; stale output trips an OLD
      flag warning/error (machine-checked, content dates — never
      run timestamps).
Acceptance: unit test with frozen clock + stale/fresh fixture feeds
      red-then-green; `podgen validate <pod>` surfaces OLD on a
      stale-dated fixture podcast; gate green.
Done: 2026-08-25. Outcome check on REAL data: lahko_noc trips
      "OLD — newest 2026-03-21, 157 days old (cadence ~1.0d)";
      six other podcasts validate fresh. Cadence inferred from
      history median gap (no config addition needed).

## P00-5 · ask-trim preview player: open → ffplay  [tier: top] [status: done — REJECTED by owner, reverted] [deps: --]
History: R0-q diagnosed `open`→Apple Music importing soon-deleted temp
mp3s (394 dead library entries, beachballs). ffplay swap implemented
2026-08-30, rejected same day: ffplay's transport is not usable for
finding cut-off points; Music's interactive controls are the
requirement. Commit 5bfca6e reverted. Ruling (2026-08-30): Music
STAYS the preview player; mitigate the library pollution instead —
research is R0-r in .docs/DECISIONS.md, implementation packet to be
elaborated after the ruling.

## P00-6 · ask-trim preview via Quick Look  [tier: top — owner-facing UX] [status: done] [deps: --]
Ruling R0-r (2026-08-30): owner trialled `qlmanage -p` on a real
episode and approved it (option B); Music-cleanup options A/D not
needed since nothing is imported anymore.
Goal: `--ask-trim` previews via Quick Look instead of `open`→Music:
      positional scrub bar + min:sec readout, zero library imports;
      spawned in background so the skip/cut prompts are live while
      the preview is open; preview auto-closes when prompts finish
      (including on `x`/exclude).
Acceptance: unit tests pin preview command = qlmanage -p, background
      spawn + TERM on completion and on exclude; existing ask_trim
      characterization tests green via the start_preview seam; gate
      green. Owner already exercised the player on the real surface.
Done: 2026-08-30. Tests red-then-green; gate 2958+50 green.
SUPERSEDED by P00-7: owner's real-run check found qlmanage neither
takes focus nor auto-plays (headless tool; autoplay would need an
Accessibility-gated keystroke hack).

## P00-7 · ask-trim preview via QuickTime Player  [tier: top — owner-facing UX] [status: done] [deps: P00-6]
Ruling (2026-08-31): owner trialled the corrected QT AppleScript
(launch via `open -a` to dodge the -600 tell-before-registered race,
then scripted `play`) on a real episode and approved.
Goal: preview opens FRONTMOST and AUTO-PLAYS; scrub + min:sec as
      before; prompts live while it plays; document auto-closes after
      prompts (incl. exclude) without relaunching a quit QT; no
      library imports.
Acceptance: unit tests pin open command, background autoplay spawn,
      and close-script invocation after prompts and on exclude;
      existing ask_trim characterization tests green via the
      start_preview seam; gate green; close script exercised once
      against a live QT window.
Done: 2026-08-31. Tests red-then-green (3 errors → green); gate
      2958+50 green; close script verified live ("closed").
      Owner confirmed in real use 2026-09-01 — packet fully closed.

---

## Phase 0 — inventory, gate + safety net

## P0-1 · The gate command  [tier: implementation] [status: done] [deps: --]
Goal: one command (`bundle exec rake gate`) = ruby syntax check over
      lib/bin/test + test:unit + test:integration_offline; wired as
      the pre-commit gate; CI wiring follows in P0-2.
Acceptance: gate red on a seeded syntax violation, green on HEAD.
Done: 2026-07-27 as part of the dev-loop migration commit.

## P0-2 · Gate in CI  [tier: implementation] [status: done] [deps: P0-1]
Goal: CI runs `bundle exec rake gate` (not just unit tests) on every
      pushed head; phase branches included.
Acceptance: a pushed commit shows the gate job green in `gh run list`;
      a deliberately red gate fails CI (red case proven locally in
      P0-1's seeded-violation check — same task CI invokes).
Done: 2026-07-27. Gate gained standardrb (matching the old CI lint
      step); ci.yml triggers on phase-* pushes and runs the gate as
      one step. Note: COVERAGE=1 now spans the whole gate, so
      simplecov also sees the offline integration tier.

## P0-3 · Module inventory memo  [tier: top] [status: done] [deps: --]
Signed off 2026-09-01 (§2 bugs → work queue Q-01…Q-12; §3 dead code
kept, Q-13; §8 seeds accepted unstruck). Same ruling: leaked queue
commit stays in history ("no big deal"); future phases get a full
plan in .docs/pXX-plan.md for owner sign-off before execution.
Goal: .docs/TOOL-REVIEW.md — per-module purpose, contracts, maturity,
      suspected weak spots, refactor candidates. Leans on
      ARCHITECTURE.md rather than duplicating it: the memo's value is
      the maturity/weak-spot/refactor columns. Reviewed WITH the
      owner; agreed findings seed Phase 1.
Acceptance: owner sign-off recorded here.

## P0-4 · Characterization audit + safety net  [tier: implementation] [status: done] [deps: P0-1, P0-3]
Goal: audit which pure logic (parsers, formatters, splitters, schema
      builders — the memo's "pure logic" list) lacks pinning tests;
      add characterization tests for the gaps. Zero production diffs.
Acceptance: memo's pure-logic list fully covered; gate green;
      `git diff lib/` empty for the packet.
Done: 2026-09-01. Audit: 37/67 targets directly covered, 9 acceptably
      via thin orchestrators, 21 gaps → 76 new exact-value tests
      across 14 files (worktree implementation agent; diff reviewed
      by orchestrator). git diff lib/ empty. Gate 3068+50 green.
      8 latent-bug candidates pinned and queued (Q-14…Q-21, unruled).

## P0-5 · Contract pinning tests  [tier: implementation] [status: done] [deps: P0-3]
Goal: explicit pinning tests for the frozen domain: RSS item shape,
      episode guid/basename scheme, history.yml / uploads.yml /
      *_timestamps.json schemas. These become the oracles that let
      cheap models work safely.
Acceptance: each frozen shape has a test that fails on any
      non-additive change; gate green.
Done: 2026-09-01. test/unit/test_frozen_contracts.rb: 5 tests / 34
      assertions pinning exact key sets, item element order, guid ==
      mp3 filename, enclosure attrs, basename suffix scheme,
      timestamps schema + reconciled-flag additivity. Oracle proven:
      red on a seeded extra feed element, green on HEAD.

## P0-6 · README honesty pass  [tier: implementation] [status: done — owner acceptance at Gate 0] [deps: P0-3]
Goal: README.md current and honest about what works today, including
      manual steps.
Acceptance: owner accepts at Gate 0.
Done: 2026-09-01. Updated: --ask-trim documented as QuickTime preview
      (flag table + interactive-trimming section); stale `[e]xclude`
      key corrected to the actual `e[x]clude`; new Development section
      (rake gate/test/health, source-registry drift rule, freshness
      OLD flag in validate). Deviation from original goal text: dead
      per-podcast upstreams (zverinice) NOT added — that is private
      podcast config (podcasts/ is gitignored) and per the 2026-09-01
      ruling internal detail stays out of the public repo; it lives in
      .docs/TOOL-REVIEW.md + guidelines instead.

## Decision items
Open items: .docs/DECISIONS.md (gitignored registry, newest first —
currently R0-p, R0-o, R0-c…R0-n, P0-3 sign-off). Landed rulings:
- R0-a Git model (2026-07-27): phase branches + human-merged PRs
  close gates; no agent pushes to master; releases are owner gate
  actions. Encoded in CLAUDE.md golden rule 3.
- R0-b Frozen domain (2026-07-27): feed/site contracts + guid/basename
  scheme + history/uploads/timestamps schemas. Encoded in CLAUDE.md
  golden rule 4.
- Phase-00 ruling (2026-08-25): conventions/infrastructure packets
  (P00-1…4) land before the rest of Phase 0.
- R0-p (2026-09-01): stray worktree commit 6dd5ba8 DISCARDED
  (worktree + branch deleted); merged refactor/dry-and-test-coverage
  pruned local + origin.
- R0-o (2026-09-01): dead-code batch KEPT documented — review item
  Q-13 in the work queue.
- R0-c…R0-n (2026-09-01): twelve inventory bugs formulated as work
  queue items Q-01…Q-12 (fix packets cut from the queue when
  scheduled).

---

## Phase 1 — correctness hardening (plan signed 2026-10-11; execution order: P1-0, P1-12, P1-1, P1-3, P1-4/5/6/9/7 (parallelizable), P1-15, P1-13, P1-2, P1-8, P1-14, P1-10, P1-16; Gate 1 = owner-merged PR)

## P1-0 · Claude model registry — one default per line, one override point  [tier: top — first-of-family pattern] [status: in-progress — code landed, outcome check pending] [deps: --]
Signed off 2026-10-10 (priority). Model IDs are hard-coded at 11
sites in 8 files with ad-hoc ENV overrides (three sites have none).
Goal: lib/claude_models.rb holds LINES (opus/sonnet/haiku → current
      undated ID, the only place a bump lands) and ROLES (each call
      site's role → line); resolution = per-role ENV > per-line ENV
      > default; existing keys keep working; a text-block helper
      replaces the 11 `content.first.text` sites before the bump
      (thinking-default models put a thinking block first).
Acceptance: unit test greps lib/ — model literals only in
      claude_models.rb; precedence table pinned; every role has an
      ENV override; the generation bump is a ≤3-line diff; one
      bajke + one news generate end to end on the bumped lines
      (owner-run); gate + CI green.
Rulings 2026-10-11 (orchestrator, by owner delegation): R1-a → CLAUDE_MODEL
      becomes an alias of CLAUDE_OPUS_MODEL; Tell translation moves to the
      sonnet line under CLAUDE_TELL_TRANSLATE_MODEL (README migration
      note). R1-b → leave default effort; step 3's two live runs record
      per-role input/output tokens in the worklog as the baseline for
      Q-28. R1-c → the keyed drift check (step 5) is IN.
Landed 2026-10-11: 869f84e (registry + text_of, zero behavior change),
      05b3e93 (bump to opus-5-5 / sonnet-5-5 / haiku-5-5 = newest served),
      + drift test. Gate 3088+50 green; drift test green live. Outcome
      check: the scheduled fulgur_news run 2026-10-11 16:30 executes from
      this checkout — its log must show the new IDs, end_turn on the
      first script attempt, and an episode; plus the next owner bajke
      generate (vocabulary present, subtitles reconciled). Status → done
      when both are read.

## P1-1 · Permission-profile audit  [tier: top — guardrail security] [status: done] [deps: --]
Goal: every invocation path to each HUMAN-action command (direct,
      bundle exec, ruby, ./bin, rake) is denied by settings.json;
      `bundle exec ruby*` allow narrowed to the test-runner form.
Acceptance: written path×rule matrix in .docs; every HUMAN action
      denied on every path (rule tracing); no legit dev command newly
      blocked.
Rulings (orchestrator, 2026-10-11): (1) a second, in-process layer is
      required — command-text rules cannot see `ruby -e`/in-process
      calls and the box's local settings allow bin/podgen:* wholesale;
      guard keys on CLAUDECODE=1, exempts --dry-run, owner override
      PODGEN_OWNER=1. (2) generate --youtube/--lingq join the owner-only
      set (listener-facing uploads; CLAUDE.md rule 3 updated).
      Done 2026-10-11: dca69d8; matrix .docs/P1-1-permission-matrix.md;
      4 stubbed guard tests red-then-green; gate 3094+50; live probes
      V2 green; V1 (deny rules applied) pending next session start.

## P1-2 · UploadsCommand boundary + observability  [tier: implementation] [status: done] [deps: --]
Goal: invalid --mode rejected in initialize (before any side effect);
      round-robin total rounds capped at the initial pending sum; one
      log line per pod on permanent-skip drain.
Acceptance: mode typo exits 2 with zero publisher calls; round cap and
      drain log pinned by tests.
Done 2026-10-11: aacc767 (worktree agent, diff reviewed). Rulings
      accepted: --mode validated in initialize via OptionParser::
      InvalidArgument (exit 2 through the dispatcher, zero collaborator
      calls — test clears CLAUDECODE so the P1-1 guard cannot mask it);
      round cap = initial pending sum (pinned: 2 pods × 2 pending that
      never drain → exactly 4 rounds); one skip-drain line per pod via
      an injectable log. Surfaced: only missing_cover counts as a
      permanent skip; other repeating permanent failures now stop via
      the cap but get no line → Q-29.

## P1-3 · Test-hygiene batch  [tier: implementation] [status: done] [deps: --]
Goal: ENV save/restore for PODGEN_ROOT and TWITTER_*; audio_trimmer
      tmp litter cleaned; explicit pathname require in the drift test;
      CI concurrency group (one run per push with an open PR).
Acceptance: full suite green under three seeds; single CI run per push.
Ruling 2026-10-11 (R1-d): lint in the gate covers new files only;
      a packet that touches a listed file removes it from
      .standard_todo.yml in the same commit when the lint diff is small;
      one-line note in README + DEV-LOOP rides this packet.
Done 2026-10-11: 52fef3b (worktree implementation agent, diff reviewed
      by the orchestrator). PODGEN_ROOT item verified already correct
      at head — no change; TWITTER_* restore fixed in
      test_twitter_agent (was prefix-guessing, not exception-safe);
      trimmer pid-named tmp files cleaned in teardown; pathname
      require; CI concurrency group. Seeds 1/2/3 green (note:
      TESTOPTS="--seed=N", the space form breaks the Rakefile); gate
      3097+50 green on phase-1.

## P1-4 · Sidecar + probe reliability  [tier: implementation] [status: done] [deps: --]
Goal: one guarded JSON load for *_timestamps.json shared by persister
      and subtitle generator; AudioAssembler probe_duration has one
      failure contract and a cache that invalidates on mtime/size.
Acceptance: corrupt sidecar → named error, not ParserError; rewritten
      file probes fresh.
Rulings (orchestrator, 2026-10-11): corrupt sidecar RAISES a named
      StandardError subclass (not nil-with-warning) so callers' rescues
      keep their statuses; both probe contracts KEPT (nil for fallback
      chains, raise inside assembly) and documented; memo keyed by
      (path, mtime, size) rather than dropped. Done 2026-10-11: aff5261;
      3 tests red-then-green; gate 3097+50 green.

## P1-5 · STT robustness  [tier: implementation] [status: done] [deps: --]
Goal: timestamp epsilon in SubtitleReconciler#validate!; engine file
      handles closed; temp names unique per thread in engines,
      AudioTrimmer, AtomicWriter.
Acceptance: 1e-6-drift reconcile fixture passes; fd count stable
      across stubbed retries; concurrent temp-name uniqueness test.
Done 2026-10-11: 6d4e859 (worktree implementation agent, diff reviewed
      by the orchestrator). Rulings (agent, accepted): epsilon 0.01 s,
      non-numeric falls back to ==; SecureRandom.hex(4) suffix rather
      than a thread id (also applied to the Groq downsample temp);
      open-then-ensure-close around each POST (minimal diff). Red for
      the right reason on all four tests; gate 3107+50 green.

## P1-6 · File hygiene  [tier: implementation] [status: done] [deps: --]
Goal: HttpDownloader writes temp + rename (no partial on size abort);
      Voicer segment cleanup in ensure.
Acceptance: size-cap abort leaves no destination file; assemble raise
      leaves no segment temps.
Done 2026-10-11: c6c0be3 (worktree implementation agent, diff reviewed
      by the orchestrator). Rulings (agent, accepted): temp+rename lives
      in write_body (redirect hops never reach it); inline .part.<pid>
      beside the destination rather than AtomicWriter (text-only API);
      Voicer ensure covers the assembly step only (TTS raise returns no
      paths to clean). Red-then-green on both tests; gate 3099+50 green.

## P1-7 · Concurrency + retry semantics  [tier: implementation] [status: done] [deps: --]
Goal: shared result hashes in EngineManager/SourceManager written
      under a Mutex (or merged after join); unreachable raise removed;
      retry attempt count pinned then documented consistently across
      Retryable and BaseEngine; status-code-based retryable? where a
      response exists.
Acceptance: characterization first, minimal diff; multi-engine
      offline tests green.
Done 2026-10-11: 9f2994f (worktree agent, diff reviewed). Rulings
      accepted: Mutex around the shared writes (smaller diff than
      merge-after-join); unreachable raise removed and the surviving
      message pinned; attempt counts UNCHANGED — both mixins already agree
      that max = retries after the first attempt (max 3 → 4 attempts), now
      documented in both; retryable? prefers response.code when present,
      else \b429\b|\b503\b. Note: the three engines raise plain
      RuntimeErrors, so the status path is dormant until an error carries
      a response.

## P1-8 · Freshness completeness  [tier: implementation] [status: done] [deps: --]
Goal: guidelines flag `freshness: off` honored by FreshnessValidator;
      a future-dated newest episode warns instead of passing forever.
Acceptance: flagged podcast validates clean; future-date fixture
      warns; existing freshness tests green.
Done 2026-10-11: dfd51e3 (worktree agent, diff reviewed). Rulings
      accepted: flag `- freshness: off` in ## Podcast (generic parser,
      no parser change); only "off" disables; accessor
      freshness_enabled? default true; future date WARNS naming the
      date. validate --all at the primary checkout: lahko_noc still OLD
      (204 d, not flagged — owner's call), fulgur_news OLD (newest
      10-07: three runs without an episode; today's 16:30 run is the
      P1-0 outcome check).

## P1-9 · Small-fix batch  [tier: implementation] [status: done] [deps: --]
Goal: normalize_url scheme match case-insensitive; TwitterAgent#
      truncate no dangling newline when url empty; ImageRanker comment
      matches code with the sort tuple pinned.
Acceptance: each characterization test flipped to the fixed behavior
      in the same commit as its fix.
Rulings 2026-10-11: R1-e → an excluded episode is a normal outcome:
      exit 0 on both the ask-trim and the length-check paths (test pins
      both). Q-20 (duplicate StatsCommand#truncate) joins this batch —
      it emits a Ruby warning on every gate run.
Done 2026-10-11: e94101a (worktree agent, diff reviewed). Ruling
      accepted from the agent on R1-e: only the interactive length-check
      EXCLUSION exits 0; the non-interactive length ABORT (no episode,
      nothing excluded) keeps exit 1 so a scheduled run that produced
      nothing stays visible. Q-12: the 2–20 range was right; the stale
      parts were field names and a removed veto. Q-20: bodies equivalent,
      duplicate removed, `ruby -w` warning count 2 → 0.

## P1-10 · Offline fixtures for network sources  [tier: implementation] [status: ready] [deps: --]
Goal: recorded, trimmed fixtures for bluesky/hn/x/claude_web parse
      paths; recording is an owner-run network task (HUMAN); parsing
      tests run in the gate.
Acceptance: each source's parse path unit-tested offline; fixtures
      registered in a fixtures README; gate green with no network.

## P1-12 · Vocabulary enrich survives one malformed object  [tier: implementation] [status: done] [deps: --]
Goal: enrich prompt pins literal English keys regardless of target
      language; a parse error on a non-truncated response falls
      through to salvage so entries before the bad object survive,
      with one logged warning.
Acceptance: fake 80-entry array with a malformed entry 40 → 39
      enrichments merged + warning (0 today); prompt test.
Ruling (orchestrator, 2026-10-11): no retry on parse failure — the
      prompt fix addresses the cause; salvage keeps what precedes the
      bad object. Done 2026-10-11: 95893e5; 2 tests red-then-green; gate
      3090+50 green; CI run 38128847434 green.

## P1-13 · Fail-fast on dead network  [tier: implementation] [status: done] [deps: P1-7]
Goal: connectivity preflight (injectable resolver against a registry
      host) aborts before Topics with a named error in under 5 s;
      bounded total retry budget for connection-class errors.
Acceptance: fake-resolver unit test; dead-DNS run exits in under a
      minute with one clear line; retry tests green.
Done 2026-10-11: b9edf12 (orchestrator). Rulings: preflight = one DNS
      lookup of a registered host, 5 s cap, injectable resolver; the
      "bounded retry budget" is delivered as the SDK client timeout
      (300 s) rather than a new budget in with_retries — the hours came
      from SDK-internal retries at the 10-min default, not from the
      2+4+8 s backoff. Marker/status surfacing → P1-14. 7 tests
      red-then-green; gate 3126+50 green; live resolver check sub-second.

## P1-14 · Scheduled content-progress check + status surface  [tier: implementation] [status: ready] [deps: P1-8]
Goal: `podgen status` prints one line per scheduled podcast (OK/OLD/
      WARN from content dates, run marker, repeated non-fatal
      warnings); `podgen schedule` prepares a daily entry and prints
      the install command (HUMAN); alert only when any pod is not OK.
Acceptance: fixtures → OLD / WARN / OK; install command printed,
      never executed by the agent.

## P1-15 · Language-suffix detection restricted to configured languages  [tier: implementation] [status: done] [deps: --]
Goal: a trailing "-xx" on an episode basename counts as a language
      suffix only when xx is one of the podcast's configured
      languages. Evidence 2026-10-11: only -es/-it/-jp exist on disk,
      so current selection is unchanged (not a frozen-domain change).
Acceptance: `pod-2026-01-01-ai.mp3` selected as English when no `ai`
      language is configured; before/after selection over the real
      output dirs identical (owner-run, printed diff empty); P0-5
      pinning tests green.
Done 2026-10-11: 7e18103 (orchestrator). Before/after English selection
      over all 7 real podcast dirs identical (suffixes on disk ⊆ configured
      codes) — not a frozen-domain change. nil/empty language list keeps
      the legacy rule. 5 tests red-then-green; one site-generator fixture
      now configures es for its -es file.

## P1-16 · YouTube OAuth loopback flow replaces OOB  [tier: top — auth flow, owner-visible] [status: ready] [deps: --]
Goal: loopback-redirect authorization replaces the discontinued
      out-of-band flow; token exchange behind a fake-able HTTP seam;
      interactive prompt in the CLI layer; refresh path untouched.
Acceptance: unit tests on the exchange with a fake seam; one owner-run
      re-auth on a clean config in the Gate 1 runbook (EXPECT lines);
      upload behavior unchanged.

## Rulings (Phase 1)
R1-a…R1-i ruled 2026-10-11 by the orchestrator under the owner's
standing delegation (implementation-level decisions never go to the
owner; only frozen-domain, phase-scope, spend-policy and owner-data
questions do). Each ruling is recorded in its packet above. R1-h:
the ten dead-code items stay KEPT; any is removed only by the packet
that next touches its file. R1-i: Q-15, Q-17, Q-18, Q-19, Q-21, Q-23
accepted as pinned behavior for Phase 1; Q-20 folded into P1-9.

## P1-11 · Script/translation max_tokens cap + no retry on truncation  [tier: implementation] [status: done] [deps: --]
Cut from Q-25 (incident 2026-10-09): on a thinking-default model the
8192 output cap was consumed by thinking + JSON → truncated
structured output → parse error → 3 identical retries per round.
Goal: max_tokens 16384 in ScriptAgent and TranslationAgent; a
      max_tokens stop with unparsable output raises
      TruncatedOutputError (not retried, message names the cap).
Acceptance: tests pin max_tokens ≥ 16384 for both agents; a
      max_tokens fake response → exactly one API call + 
      TruncatedOutputError; gate + CI green; one news generate on
      the current CLAUDE_MODEL reaches end_turn on attempt 1
      (owner-run).
Done: 2026-10-10. Commit bdefdc8; 7 tests red-then-green; gate
      3075+50 green; CI run 38071749573 green. Outcome check on the
      real surface (news generate on opus-5-5) is owner-run — see
      runbook in the handoff; not claimed here.
