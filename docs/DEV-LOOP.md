# DEV-LOOP.md — driving podgen's implementation with Claude models

*How this project gets built with maximum unattended automation,
minimum top-tier spend, and explicit human gates. Instantiated from
the dev-loop skill (ancestry: nabu → mimir → arbot).*

## 1. Preconditions the loop needs

- **Machine-checkable done:** `bundle exec rake gate` green is the
  pre-commit gate (syntax + unit + offline integration). No network
  in gate-tier tests; fully deterministic verification.
- **Frozen contracts as oracles:** pinning tests on feed/site output
  shapes, episode naming, and history/uploads/timestamps schemas
  grade the work, not judgment.
- **Minimal-diff / TDD rules** make packets naturally PR-sized.
- **Phases with review gates** are the standing human approval
  points — the loop never invents its own.

Podgen is brownfield: Phase 0 (section 5) runs before ANY feature
work.

## 2. Model tiering policy

**Tiers are roles, not fixed model names.** Re-evaluate the mapping
as models ship; newer cost-effective models are first-class coding
agents for any packet with a written spec and a machine-checkable
oracle. Top tier is NOT the default; a `[tier: top]` tag on a coding
packet carries a one-line justification.

| Tier | Used for |
|---|---|
| **Top** (orchestrator) | Phase/architecture design; packet elaboration; first-of-family patterns; anything touching the frozen domain (feed/site contracts, guid scheme, history/uploads schemas), frozen contracts, or secrets (proposal-only — final say is the owner's); review of every delegated diff; gate reviews; blocked-packet adjudication; upstream-breakage forensics (e.g. dead RTVSLO feeds) |
| **Implementation** | Standard implementation against a written spec with an oracle; test batteries; glue; refactors the suite pins; fixture entries; doc syncs; worklog/backlog housekeeping — pick the CHEAPEST tier plausibly capable |

Hard rule regardless of tier: **no model changes the frozen domain,
frozen contract fields, or owner-governed data files** (history.yml,
uploads.yml, podcasts/*/guidelines.md edits beyond what a packet
explicitly grants). Those become `blocked: decision-item`.

**Agent safety:** code agents run in worktree isolation
(`isolation: "worktree"`) — this tree hosts live owner data under
output/. Every agent prompt carries an explicit
no-destructive-git-commands constraint (no rm -rf, no git
checkout/reset of files the agent didn't create).

## 3. Work packets and the backlog

docs/BACKLOG.md (see its header for the format) is the loop's entire
coordination state — no external tracker; survives any session dying.
Research memos, phase plans, and gate runbooks live in gitignored
.docs/; open owner decisions in .docs/DECISIONS.md (newest first,
removed once ruled — the ruling lands in the affected packet).

## 4. Loop mechanics

1. **Pick** the first `ready` packet whose deps are `done`.
2. **Dispatch** at the packet's tier.
3. **Implement TDD**: characterization/failing test first, then the
   minimal diff to green.
4. **Verify**: `bundle exec rake gate` green + self-review checklist;
   contract-touching work diffs the output shape against the pinning
   test (updated in the SAME commit, additively).
5. **Commit** on `phase-N` referencing the packet; update backlog +
   worklog; push the phase branch and WATCH CI (`gh run list`) —
   CI is the authority.
6. **Escalate on failure**: two failed attempts at tier → bump one
   tier, retry once; two failures at top → `blocked: <diagnosis>`,
   move on. Frozen-domain packets skip attempts → `blocked:
   decision-item`.
6b. **Visual work reviews itself first.** Anything rendered (site
   pages, video output) gets a headless screenshot of the SERVED
   surface that the executing session READS and critiques before
   owner handoff.

   **Surface review checklist** (liveness markers alone are never
   sufficient):
   - [ ] every expected element present AND filled
   - [ ] elements in the correct order and place
   - [ ] latest data points visible and RECENT for each element's
         own cadence — read the dates on the page, not the badge
   - [ ] no NaN / null / undefined rendered anywhere
   - [ ] cross-element consistency: the same fact shown twice agrees
   - [ ] failure states are the DESIGNED ones, never blank space
   - [ ] every interactive element responds (one pass each)
   - [ ] browser console clean
   - [ ] real rendered geometry + the mobile breakpoint
   - [ ] day-over-day: vs the previous screenshot, the data MOVED
7. **Pre-gate: README.md current** — honest about what does not work
   yet. A phase is not gate-ready with a stale README. Check
   ARCHITECTURE.md freshness the same way.
8. **Phase gate**: CRPR review (worktree `/cr` agent) of the entire
   phase diff against ARCHITECTURE.md; resolve blocked packets;
   update the "Current phase" line in CLAUDE.md; open a PR from
   `phase-N` to `master`; produce the gate handoff as a RUNBOOK
   (numbered steps, one command each, EXPECT lines; background
   quarantined at the end). **The owner executes the gate's human
   actions and merges the PR — the merge IS the gate-closing event.**
   Releases (`gh release create`, Homebrew formula auto-update) are
   owner gate actions. Next phase's packets are elaborated only
   after the gate closes.
9. **Ring for the owner** when the loop stops on something only the
   owner can do (gate handoff, all-blocked, decision item) — as the
   LAST tool call of that turn:
   `nohup "$HOME/.claude/hooks/attention-alarm.sh" sticky >/dev/null 2>&1 &`
   Never for informational turns.

## 5. Execution modes

- **Phase 0 (brownfield hardening): interactive, top-tier code.**
  Inventory memo → gate command → characterization net → seams,
  fixtures, contract tests → owner-approved refactors only. Owner
  present; bugs found are decision items, never silent fixes.
- **Stage A (new features): top-tier-orchestrated, semi-attended.**
  Orchestrator elaborates and reviews; implementation tiers write
  most code via subagents at the packet's tier.
- **Stage B (assembly line): mid-tier-led, mostly unattended.** A
  mid-tier main session runs the loop, dispatching down-tier and
  spawning top-tier subagents only for gate reviews and
  adjudication. Fresh context per packet prevents drift; the backlog
  carries state.

## 6. Guardrails

Principle: **inside the sandbox, full freedom — the boundary itself
is hard** (.claude/settings.json).

Freely allowed: file operations inside the repo + scratchpad; the
gate and test commands; dry-run modes; git on phase branches
(including push); doc/web lookups.

Hard boundary (deny-listed or owner-only): pushes to `master`, force
pushes, tags, `gh release create`; listener-facing CLI commands
(`podgen publish/unpublish/uploads/tweet/schedule/analytics`);
secrets (never Read .env — ENV names only); new dependencies;
writing owner-governed data files (history.yml, uploads.yml) outside
an explicitly granted packet.

Loop discipline: two-strike rule bounds spend; the loop never marks
its own phase done; no opportunistic refactors; owner-facing
verification asks are always SPECIFIC (exact commands, files, and
what good/bad looks like).

## 7. Human-action inventory

| When | Action |
|---|---|
| Phase 0 | Review the inventory memo; approve the refactor list; accept README v1 |
| Fixtures | Run fixture-recording tasks (network); review the diff |
| Gates | Merge the phase PR; releases/tags; publish runs; visual sign-offs |
| Always | Rulings on decision items; frozen-domain changes; guidelines.md editorial changes |

## 8. Ops pattern

Podgen schedules work (launchd via `podgen schedule`). Each
scheduled producer carries a content-progress invariant on its
OUTPUT (`podgen validate` / `podgen stats` are the natural probes):
if the published tail (feed lastBuildDate vs newest episode date on
the served feed) stops moving beyond its cadence, that trips a
visible OLD flag, not silence. Decommissioning any scheduled job
follows the inventory rule (CLAUDE.md verification discipline #3).
