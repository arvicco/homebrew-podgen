# Backlog — podgen

Flat, human-editable packets; the loop's entire coordination state.
Statuses: ready → in-progress → done | blocked: <reason>.
Packet IDs: M<phase>-<n>. Decision items: D<phase>-<letter>, ruling
recorded inline when it lands. The executing session updates its own
packet's status and appends one worklog paragraph per completed
packet.

Packet format:

## M0-1 · <title>  [tier: <model-or-role>] [status: ready] [deps: --]
Goal: <one testable outcome>
Acceptance: <the machine-checkable oracle: which tests/checks prove it>

---

## Phase 0 — inventory, gate + safety net

## M0-1 · The gate command  [tier: implementation] [status: done] [deps: --]
Goal: one command (`bundle exec rake gate`) = ruby syntax check over
      lib/bin/test + test:unit + test:integration_offline; wired as
      the pre-commit gate; CI wiring follows in M0-2.
Acceptance: gate red on a seeded syntax violation, green on HEAD.
Done: 2026-07-27 as part of the dev-loop migration commit.

## M0-2 · Gate in CI  [tier: implementation] [status: ready] [deps: M0-1]
Goal: CI runs `bundle exec rake gate` (not just unit tests) on every
      pushed head; phase branches included.
Acceptance: a pushed commit shows the gate job green in `gh run list`;
      a deliberately red gate fails CI.

## M0-3 · Module inventory memo  [tier: top] [status: ready] [deps: --]
Goal: docs/TOOL-REVIEW.md — per-module purpose, contracts, maturity,
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

## Decision items — Phase 0
- D0-a Git model ruling (2026-07-27): phase branches + human-merged
  PRs close gates; no agent pushes to master; releases are owner gate
  actions. RULED — encoded in CLAUDE.md golden rule 3.
- D0-b Frozen domain ruling (2026-07-27): feed/site contracts +
  guid/basename scheme + history/uploads/timestamps schemas.
  RULED — encoded in CLAUDE.md golden rule 4.
