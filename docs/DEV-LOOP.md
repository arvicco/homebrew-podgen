# DEV-LOOP.md — driving podgen's implementation with Claude models

*How this project gets built with maximum unattended automation,
minimum top-tier spend, and explicit human gates. Instantiated from
the dev-loop skill (ancestry: nabu → mimir → arbot); synced to
dev-loop v2.1 (doctrine.md + boards.md) on 2026-10-11, re-synced on
2026-10-28 to origin/main 966b93b (doctrine §17a–§27, the phase
register, the gate health sweep) and on 2026-11-13 to origin/main
2e4c0cf (doctrine §28–§32; the §1 one-command rule; the §6
no-blocking-prompts sharpening; the §7 completion-surface rule with
its inline check stamp; §13 temporal privacy; §16 one canonical home;
the §25 action-relay widening; the detached-run / chain-run runner
pair) — those two files are binding and are NOT duplicated here;
section 4 is a working copy that CITES them and is checked against
them at every re-sync (§16); section 9 maps the sections that need a
podgen reading.*

## 1. Preconditions the loop needs

- **Machine-checkable done:** `bundle exec rake gate` green is the
  pre-commit gate (syntax + lint + unit + offline integration). Lint
  covers files not listed in .standard_todo.yml (ruling R1-d: a packet
  that touches a listed file removes it from the list in the same
  commit when the lint diff is small). No network in gate-tier tests;
  fully deterministic verification.
- **Frozen contracts as oracles:** pinning tests on feed/site output
  shapes, episode naming, and history/uploads/timestamps schemas
  grade the work, not judgment.
- **Minimal-diff / TDD rules** make packets naturally PR-sized.
- **Phases with review gates** are the standing human approval
  points — the loop never invents its own.

Podgen is brownfield: Phase 0 (section 5) ran before any feature work
(closed 2026-09-02); every later phase builds on its gate, fixtures and
characterization net.

## 2. Model tiering policy

**Tiers are roles, not fixed model names.** Re-evaluate the mapping
as models ship; newer cost-effective models are first-class coding
agents for any packet with a written spec and a machine-checkable
oracle. Top tier is NOT the default; a `[tier: top]` tag on a coding
packet carries a one-line justification.

| Tier | Used for |
|---|---|
| **Top** (orchestrator) | Phase/architecture design; packet elaboration; first-of-family patterns; anything touching the frozen domain (feed/site contracts, guid scheme, history/uploads schemas), frozen contracts, or secrets (proposal-only — final say is the owner's); review of every delegated diff; gate reviews; blocked-packet adjudication; upstream-breakage forensics (e.g. dead RTVSLO feeds) |
| **Implementation** | Standard implementation against a written spec with an oracle; test batteries; glue; refactors the suite pins; fixture entries; doc syncs; worklog/backlog housekeeping — delegated to Opus-class subagent lanes in worktrees (`model: "opus"`, doctrine §17); the brief carries the file list, the failing-test plan, the house rules and the commands that must be green |

Hard rule regardless of tier: **no model changes the frozen domain,
frozen contract fields, or owner-governed data files** (history.yml,
uploads.yml, podcasts/*/guidelines.md edits beyond what a packet
explicitly grants). Those become `blocked: decision-item`.

**Agent safety:** code agents run in worktree isolation
(`isolation: "worktree"`) — this tree hosts live owner data under
output/. Every agent prompt carries an explicit
no-destructive-git-commands constraint (no rm -rf, no git
checkout/reset of files the agent didn't create).

**Worktree lint parity (Q-49):** Standard ignores `bin/*` by default,
but RuboCop skips that Exclude during file discovery when the base
directory has a dot-component (`.claude/worktrees/...`), so a lane's
gate linted bin/podgen and bin/tell while the checkout and CI did not.
Their offenses are listed per-cop in .standard_todo.yml (per-cop
excludes apply on either path), so both agree on the offenses that
exist today; a new offense in bin/ under another cop would still fail
only in a worktree until it is added there too.

## 3. Work packets and the boards

IDs: packets P<phase>-<n>, rulings R<phase>-<nn>, queue Q-n, incidents
I-n. BOARDS profile (R1-k, 2026-10-11): gitignored .docs/ holds the
phase plan (p<N>-plan.md — the owner's one surface per phase; packet
status and the phase worklog live in it), WORK-QUEUE.md, DECISIONS.md
(open rulings only, written for the decision-maker; ruled items
removed entirely; CALENDAR + slate matters), incident-register.md (a
log, newest first), phase-register.md (the owner-faced cost-and-yield
ledger: one brief entry per phase, newest first, appended at every
gate closure — bare phase length + "(PR #n, merged date)", then short
labeled bullet groups Shipped / Boards / Incidents / Open, one item
per line, never fused), phase-clock (the §21 clock: adoption and
handover timestamps of the running phase) and old-phases/ (closed
plans; the pre-Phase-2 docs/BACKLOG.md and WORKLOG.md are archived
there as backlog-2026-10-11.md / worklog-2026-10-11.md). The boards
are gitignored and keep full timestamps; tracked files carry dates
only (item 19).

## 4. Loop mechanics

1. **Pick** the first `ready` packet whose deps are `done`.
2. **Dispatch** at the packet's tier. A lane brief states HOW every
   census figure in it was taken (the grep, the query, the sample
   frame) so the lane can reproduce it, and the lane re-censuses
   before building and reports the delta (§17a). A brief or wrapper
   for a runner that executes a SEQUENCE of live slices (a fixture
   recording series, a batch of regens, a revocab pass, a multi-source
   sync) carries four lines, none optional (§17b): a timeout of 2× the
   last measured wall time with a 90-minute floor; a budget stop at
   which it reports and stops; a first-failure stop; tail verification
   (the last slice's counts against its expectation) before "done".
   The wrapper half is a TOOL, not a convention: the plugin's
   `scripts/detached-run.sh` (nohup + pidfile + STOP file + hard
   timeout + a worded verdict with `.exit`/`.FAILED` sentinels) and
   `scripts/chain-run.sh` (one verdict per step, exit = the OR of its
   members, a dedicated `.events` signal surface) — never a hand-
   written nohup dance. The review of batch code checks that every
   rescue path records-and-skips or re-raises. A background rider (a
   paced crawl, a long fetch) is sized to the phase: it stops at its
   next clean boundary when the last code lane lands (§24).
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
8. **Phase gate**: the gate PR is opened only when the phase is
   reviewed and ready to merge — never at phase start, never as a
   living document (owner ruling 2026-10-16; the plan in .docs/ is the
   living document); its body is the final summary + runbook;
   CRPR review (worktree `/cr` agent) of the entire phase diff against
   ARCHITECTURE.md; resolve blocked packets; board hygiene sweep
   (register/queue residue, incident rows advanced, calendar); the
   live health-invariant sweep (`podgen status`, read-only, against
   the live surfaces — a new deviation is gate work, not a note);
   update the "Current phase" line in CLAUDE.md; produce the gate
   handoff as a RUNBOOK (numbered steps, one command each, EXPECT
   lines; background quarantined at the end). The handoff text, the
   PR body and the plan doc all carry the phase wall-time line (§21,
   item 10). **The owner executes the gate's human actions and merges
   the PR — the merge IS the gate-closing event.** Gate CLOSURE (on
   the merge): verify the merge with a live query, delete the phase
   branch both ends, stamp the plan CLOSED and archive it, archive the
   queue and remove adopted entries, advance incident rows, APPEND the
   phase-register entry (the closure checklist's last step), then
   present the next slate ON ASK. **The slate never self-adopts**
   (boards.md lifecycle 1 and 6): no lane, read, census or any other
   spend starts before the owner names the phase; a refill read of a
   thin queue is a slate OPTION like any other, never an automatic
   step (owner correction 2026-11-13, after three review lanes were
   spawned at a gate close with no slate presented). Releases
   (`gh release create`, Homebrew formula auto-update) are owner gate
   actions. The next phase is elaborated only after the gate closes,
   as a FULL plan in `.docs/pXX-plan.md` (scope, packets with
   goals/acceptance, decision items, risks) that the owner signs off
   BEFORE execution starts (owner ruling 2026-09-01).
9. **Never idle, never block** (doctrine §6): a turn ends only at the
   gate or on a genuinely empty workfront; waiting on background work
   prints "independent items remaining: N" with N = 0; long waits arm
   the kick/stay waker. An adopted phase is an UNATTENDED window: no
   blocking interactive prompt (AskUserQuestion or any modal) fires
   during a phase, least of all at adoption; the interaction model is
   register rows + chat read at will + the turn-end alarm. A slate
   candidate is adoptable on the adoption word ALONE — "the owner
   rules X at adoption" is a forbidden pre-condition; mint the ruling
   when it is identified and register-gate only the dependent
   packets (§6, sharpened 2026-11-06). **Ring for the owner** when the
   loop stops on something only the owner can do (gate handoff,
   all-blocked, decision item) — as the LAST tool call of that turn:
   `nohup "$HOME/.claude/hooks/attention-alarm.sh" sticky >/dev/null 2>&1 &`
   Never for informational turns. The one-line closer that follows
   the alarm opens with the clock line (item 10) and names the one
   thing awaiting the owner — and carries an owner-state claim only
   when the same turn ran the live query (item 12).
10. **The phase clock** (§21): at adoption the loop writes the
   adoption timestamp to `.docs/phase-clock` (the branch-cut reflog is
   the recoverable anchor); at the gate it adds the handover
   timestamp. EVERY owner-facing message — status, mid-phase note,
   handoff, the post-alarm closer — opens with one short line:
   "2h30m since adoption" while the phase runs, "2h30m adoption→gate
   handover" from the gate on. The line is the phase's cost figure,
   not formatting; it goes into the plan doc, the PR body and the
   handoff text, every gate, no exceptions.
11. **A decision item exists only as a minted register row** (§26):
   a decision reaches the owner only as a .docs/DECISIONS.md row with
   options and a recommendation. "Awaiting approval" in plan prose, a
   deliverable "surfaced for review", a held pick "awaiting the word"
   hang on nobody and are never reported as owner actions. An adopted
   packet's researched recommendation IS the authorization: execute
   it and report. A genuinely open owner choice mid-work → mint the
   row at once, never nag the chat. **No manufactured decisions** (§7,
   second offense 2026-11-05): the register row form is reserved for
   items whose OPTIONS are honestly undecidable without the owner; a
   row whose own text carries a confident recommendation is self-
   indicting — the loop resolves it from the system's standing
   patterns, records "resolved by loop ruling" in the plan, and moves
   on. Only genuine forks, structure-inventing calls, scope, identity,
   money and listener-visible or frozen-domain choices go up.
12. **Owner-state lines are derived, never copied** (§27) **and carry
   their check inline** (§7, 2026-11-05): any message carrying an
   OWNER ACTIONS line or a claim about PR states, drafts, sends or run
   outcomes is composed by first running the live query bundle
   (`gh pr view --json state,mergedAt` for every PR it will name;
   `gh pr list --state open`; the completion record of every other
   act it will request), then writing the lines only from that output;
   an unsubstantiated line is dropped, not softened. The query is OF
   THE SURFACE THE LINE CLAIMS — its COMPLETION RECORD (the merge
   state, the run log's RUN-OUTCOME line, the batch summary, the
   consent token's size, the posted URL), never an absence-of-activity
   surface (process tables, lock files, bare mtimes prove only "not
   running now"). FORMAT CONTRACT: every owner-action line and
   external-state claim carries its evidence inline — "(checked HH:MM
   CST: <surface> → <state>)" — and a line that cannot cite its check
   does not ship. Boards — and the loop's own prior messages, and a
   compaction summary — are never a source for an owner-state line;
   they are what gets corrected when the query contradicts them, in
   the same turn. The plugin's `nag-guard.sh` Stop hook blocks a
   turn-ending that hands the owner an unstamped action (not armed on
   this box until the installed plugin is refreshed — see item 17).
13. **Surveys end in minted items** (§22): an owner-ordered survey or
   read ends with every adoptable finding as a queue item with the
   verification already done, a register row where an owner call is
   genuinely needed, or an explicit KILLED line; "for the owner's
   consideration" lists are the named failure mode.
14. **Repeated operations assert their own yield** (§28, 2026-11-09):
   any loop-fired chain of slices (a regen series, a fixture recording
   series, a revocab pass over a show, a batch of re-reads) measures
   its output delta every iteration from the tool's own accounting
   line (files landed, segments reconciled, entries written); a
   zero-delta iteration BREAKS the chain and surfaces — log line +
   stop, never a silent next lap; a tool whose progress line does not
   print on some path is itself a defect. An anomaly never gets a
   soothing adjective ("harmless", "benign", "cosmetic", "expected")
   without the check that earns it quoted in the same turn; the
   honest form is "anomaly, cause unknown, checking", and on a live
   surface that means an incident row + investigation item at once.
15. **A fired long op is MONITORED, not awaited** (§29, 2026-11-11):
   any loop-fired operation expected to run longer than ~10 minutes
   gets its watchdog armed in the SAME turn that fires it — exit
   notification; bounded re-invoke checkpoints (≤ 30 min) that read
   the op's OWN progress ticks; an overrun deadline from the op's
   timing ledger (2× measured, never a guess) past which the wake
   surfaces kill/wait to the owner with the evidence gathered. A
   stalled tick stream is the alarm condition, not "still running".
   Podgen's candidates: revocab passes, fixture series, regen chains.
16. **Owner-fired op outcomes are VERIFIED at first contact; incidents
   LEAD** (§30, 2026-11-11): at the loop's first contact after any
   owner-fired long op — a production generate, the 10:30 upload
   batch, a manual regen, a history rewrite — verify the op's outcome
   from its durable record (the run log's RUN-OUTCOME line, the batch
   summary, the git refs) BEFORE building anything on its output; a
   killed run writes nothing, so silence is what gets audited. An
   incident-grade discovery opens the next owner report as its FIRST
   line, named plainly — never a clause inside the answer to
   something else.
17. **Compaction is a steered handoff** (§31, 2026-11-12): the plugin's
   PreCompact hook makes every summary a duty handoff (undelivered
   verdicts first and marked; every external-state line "snapshot —
   re-verify"; in-flight ops with ids and watchdogs; the exact next
   step; standing rules verbatim), and its SessionStart(compact) hook
   makes the resumed turn deliver undelivered verdicts first and
   re-earn every external-state line live. Continuity never lives
   only in context: the plan doc, phase clock, registers and task ids
   in the worklog are kept current DURING work, so a compaction loses
   prose, never state. On this box the installed plugin is still
   cache 1.1.1 (no doctrine.md, no nag-guard, no compaction hooks;
   the marketplace path is the local clone, 45 commits behind
   origin/main on 2026-11-13) — the session runs unprotected until
   the clone is brought to origin/main and the plugin refreshed.
18. **A chained op's detected failure surfaces itself** (§32,
   2026-11-12): a chained or multi-step background op gets a
   failure-line Monitor armed in the same tool turn it is fired,
   watching a DEDICATED signal surface (the runner's `.events`,
   `.FAILED` and `.exit` files) — never `tail -f <progress log> |
   grep`, which turns a watch into a firehose. Chain scripts print
   one worded verdict per step ("ok exit=0" / "FAILED exit=N"), one
   ALL-DONE line, and exit with the OR of their members; no neutral
   "exit=N" lines anywhere, and `|| true` only with a same-line
   comment naming why that failure is ignorable. Status lines about
   the loop's own ops are earned like external state: the log or
   ledger is read immediately before composing, every time.
19. **Temporal privacy on public surfaces** (§13, 2026-11-03): the
   clock behind the work is private data. Tracked files, commit
   messages, PR bodies and site prose carry DATES as the finest time
   grain — never clock times, zone suffixes or offsets, never
   day-parts ("overnight", "this morning"), never working-hours
   narrative; durations ("52m", "1h 5m") measure the work and stay.
   The gitignored boards keep full timestamps. The CLAUDE.md phase
   line was stripped of clock times on 2026-11-13; the loop commits
   with `TZ=UTC`. Upstream's own cadence and listener-facing episode
   metadata are content, not a leak (the feed's pubDate question is
   R18-02).
20. **One command for an owner-run operation; one canonical home per
   rule** (§1 2026-11-02, §16 2026-11-02): when an identity act
   genuinely needs the owner to RUN something, it is handed over as
   ONE packaged command (a rake task or script carrying its preflight,
   setup and post-verification), never a sequence of incantations.
   Every process rule lives in exactly one canonical home — doctrine.md
   / boards.md for the general loop, CLAUDE.md for podgen-specific
   rules, memory for session-learned nuance; this file is a working
   copy that cites them and is re-checked against them at every
   re-sync, and a paraphrase that drifts stronger or weaker than the
   owner's words is the defect.

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

Hard boundary (owner-only, enforced by the dispatcher's `CLAUDECODE=1`
refusal; the settings.json deny list only catches the literal flags and
is a convenience layer, not the enforcement): pushes to `master`, force
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
| Always | Rulings on decision items; frozen-domain changes; guidelines.md editorial changes; naming the phase from the slate |

## 8. Ops pattern

Podgen schedules work (launchd via `podgen schedule`). The
content-progress invariant is IMPLEMENTED (P00-4):
`Validators::FreshnessValidator`, run by `podgen validate`, compares
the newest episode's content date to the wall clock against a
cadence inferred from history (median gap); a stalled producer trips
a visible OLD flag, not silence. The source registry (P00-3,
`lib/source_registry.rb`) covers the other half: `rake health`
probes every hard-coded endpoint, and the gate fails when lib/
gains an unregistered host. Decommissioning any scheduled job
follows the inventory rule (CLAUDE.md verification discipline #3).
Since Phase 7 every generate ends its log with a `RUN-OUTCOME` line
and `podgen status` reads it, the upload trackers and the served
feed — that board IS the health-invariant sweep run at every gate,
and the RUN-OUTCOME line is the completion record §30 reads first.

## 9. Doctrine sections with a podgen reading (re-sync 2026-11-13)

- **§19 axis-mapping is parse work:** a new source or feed intake
  (a podcast's guidelines, a research source) maps upstream metadata
  onto the existing config/taxonomy at parse time as the loop's call,
  recorded in the adapter or config with its reasoning; a register
  row only when the taxonomy itself would change or the call is
  costly to reverse.
- **§20 expensive owner-fired replays:** podgen has no owner-fired
  regeneration step today (regens and fixture refreshes are loop
  work). The absolute reading that DOES apply: the loop never
  schedules or touches an owner-only operation — publish, uploads,
  OAuth consent, a manual generate of a missed episode — never
  attaches a "now" or an urgency to it, and restates what waits on it
  only when asked. If an owner-fired replay ever appears, slates
  sequence dirt-first around it.
- **§23 cost classifies derived data:** paid transcription and
  reconciliation products already live outside the routine regen
  (`regen --reconcile` is an explicit flavor); any future hours-long
  derived product follows the same rule — its own command, stored
  with provenance, staleness visible on the status board.
- **§25 the relay runs one direction; action-relays:** podgen has no
  relay protocol (no owner-approved sends to external channels); if
  one appears, every post is the loop's act behind the owner's one
  send, never a form-filling walkthrough handed back, and any
  automatable act of arguable authority is drafted as "channel:
  action — what, against which surface, under which ruling, expected
  result" for the owner's one word.
- **§7 outbound channels are inbound duties:** the product's own
  publishers (tweets, Bluesky, YouTube, LingQ) are listener-facing
  output, not loop-opened channels; the loop opens no channel today.
  If it ever posts anywhere on the owner's behalf, the return path is
  enumerated in the same edit that records the post.
- **§13 temporal privacy, podgen surfaces:** CLAUDE.md's phase line,
  README, ARCHITECTURE, commit messages and PR bodies carry dates
  only. Episode `pubDate` and `lastBuildDate` in the served feeds are
  listener-facing RSS metadata minted at generation time with the
  Mac's zone offset — a frozen-domain surface, so whether to normalize
  them is R18-02, not a loop call.
- **§28–§32 in podgen terms:** the loop's chains are regen series,
  fixture recording series and revocab passes — each runs under
  `detached-run.sh` + `chain-run.sh` with a Monitor on the `.events`
  surface, a yield assertion per slice, and an owner line only after
  the log is read. The owner's long ops are the production generates,
  the 10:30 batch and anything done to the repository between
  sessions; their records (RUN-OUTCOME, the batch summary, `git
  fetch` + the PR state) are read before any work builds on them, and
  a found incident leads the next report.
- **Clock backfill:** the register's historical entries carry phase
  lengths reconstructed from the branch's first and last commits and
  the PR timestamps, marked approximate; from Phase 9 on the clock
  file is the source.
