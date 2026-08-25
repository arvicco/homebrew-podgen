# Backlog — podgen

Flat, human-editable packets; the loop's entire coordination state.
Statuses: ready → in-progress → done | blocked: <reason>.
Packet IDs: M<phase>-<n>. Decision items: D<phase>-<letter> — OPEN
items live in .docs/DECISIONS.md (gitignored, newest first, removed
when ruled); the ruling is recorded inline in the affected packet.
Research/planning docs live in gitignored .docs/. The executing
session updates its own packet's status and appends one worklog
paragraph per completed packet.

Packet format:

## M0-1 · <title>  [tier: <model-or-role>] [status: ready] [deps: --]
Goal: <one testable outcome>
Acceptance: <the machine-checkable oracle: which tests/checks prove it>

---

## Phase 00 — conventions & loop infrastructure (owner ruling 2026-08-25:
land these before the rest of Phase 0)

## M00-1 · .docs workspace + decisions registry  [tier: top] [status: done] [deps: --]
Goal: gitignored .docs/ holding research/planning docs; open owner
      decisions in .docs/DECISIONS.md (newest first, removed when
      ruled); TOOL-REVIEW.md relocated; dev-loop plugin templates
      updated to encode the convention.
Acceptance: .docs/ ignored by git; DECISIONS.md seeded with all open
      items; no tracked process artifacts beyond BACKLOG/WORKLOG.
Done: 2026-08-25.

## M00-2 · Verification-discipline + alarm doc sync  [tier: implementation] [status: done] [deps: --]
Goal: CLAUDE.md gains discipline items 5 (specific verification asks)
      and 6 (commit owner-session data immediately); DEV-LOOP.md §4
      gains the ring-for-owner alarm step.
Acceptance: both docs match the dev-loop skill's six-item discipline;
      gate green (docs-only).
Done: 2026-08-25.

## M00-3 · Source registry  [tier: top — first-of-family seam design] [status: done] [deps: --]
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
      by podgen validate + M00-4, not the registry.
Done: 2026-08-25. `rake health` 14/14 OK (elevenlabs probe URL fixed
      after first live run).

## M00-4 · Content-progress (freshness) invariant  [tier: implementation] [status: ready] [deps: --]
Goal: lib/validators/freshness_validator.rb wired into podgen
      validate: newest episode date in the generated feed vs wall
      clock against the podcast's cadence; stale output trips an OLD
      flag warning/error (machine-checked, content dates — never
      run timestamps).
Acceptance: unit test with frozen clock + stale/fresh fixture feeds
      red-then-green; `podgen validate <pod>` surfaces OLD on a
      stale-dated fixture podcast; gate green.

---

## Phase 0 — inventory, gate + safety net

## M0-1 · The gate command  [tier: implementation] [status: done] [deps: --]
Goal: one command (`bundle exec rake gate`) = ruby syntax check over
      lib/bin/test + test:unit + test:integration_offline; wired as
      the pre-commit gate; CI wiring follows in M0-2.
Acceptance: gate red on a seeded syntax violation, green on HEAD.
Done: 2026-07-27 as part of the dev-loop migration commit.

## M0-2 · Gate in CI  [tier: implementation] [status: done] [deps: M0-1]
Goal: CI runs `bundle exec rake gate` (not just unit tests) on every
      pushed head; phase branches included.
Acceptance: a pushed commit shows the gate job green in `gh run list`;
      a deliberately red gate fails CI (red case proven locally in
      M0-1's seeded-violation check — same task CI invokes).
Done: 2026-07-27. Gate gained standardrb (matching the old CI lint
      step); ci.yml triggers on phase-* pushes and runs the gate as
      one step. Note: COVERAGE=1 now spans the whole gate, so
      simplecov also sees the offline integration tier.

## M0-3 · Module inventory memo  [tier: top] [status: blocked: decision-item (owner sign-off, see .docs/DECISIONS.md)] [deps: --]
Goal: .docs/TOOL-REVIEW.md — per-module purpose, contracts, maturity,
      suspected weak spots, refactor candidates. Leans on
      ARCHITECTURE.md rather than duplicating it: the memo's value is
      the maturity/weak-spot/refactor columns. Reviewed WITH the
      owner; agreed findings seed Phase 1.
Acceptance: owner sign-off recorded here.

## M0-4 · Characterization audit + safety net  [tier: implementation] [status: ready] [deps: M0-1, M0-3]
Goal: audit which pure logic (parsers, formatters, splitters, schema
      builders — the memo's "pure logic" list) lacks pinning tests;
      add characterization tests for the gaps. Zero production diffs.
Acceptance: memo's pure-logic list fully covered; gate green;
      `git diff lib/` empty for the packet.

## M0-5 · Contract pinning tests  [tier: implementation] [status: ready] [deps: M0-3]
Goal: explicit pinning tests for the frozen domain: RSS item shape,
      episode guid/basename scheme, history.yml / uploads.yml /
      *_timestamps.json schemas. These become the oracles that let
      cheap models work safely.
Acceptance: each frozen shape has a test that fails on any
      non-additive change; gate green.

## M0-6 · README honesty pass  [tier: implementation] [status: ready] [deps: M0-3]
Goal: README.md current and honest about what works today, including
      known-dead upstreams (e.g. zverinice feed) and manual steps.
Acceptance: owner accepts at Gate 0.

## Decision items
Open items: .docs/DECISIONS.md (gitignored registry, newest first —
currently D0-p, D0-o, D0-c…D0-n, M0-3 sign-off). Landed rulings:
- D0-a Git model (2026-07-27): phase branches + human-merged PRs
  close gates; no agent pushes to master; releases are owner gate
  actions. Encoded in CLAUDE.md golden rule 3.
- D0-b Frozen domain (2026-07-27): feed/site contracts + guid/basename
  scheme + history/uploads/timestamps schemas. Encoded in CLAUDE.md
  golden rule 4.
- Phase-00 ruling (2026-08-25): conventions/infrastructure packets
  (M00-1…4) land before the rest of Phase 0.
