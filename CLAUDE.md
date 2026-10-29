# CLAUDE.md — podgen

Autonomous podcast generation pipeline (Ruby 3.4+, macOS): two
pipelines (news, language) + Tell CLI/web. See README.md for usage and
ARCHITECTURE.md for design — read ARCHITECTURE.md before any
non-trivial task. Read docs/DEV-LOOP.md before any non-trivial task.
BOARDS profile (owner ruling R1-k, 2026-10-11): ALL coordination state
lives in gitignored .docs/ — the phase plan (.docs/pXX-plan.md: owner-
signed BEFORE a phase executes; packet status + the phase worklog live
in it), the work queue (.docs/WORK-QUEUE.md, Q-nn), the open rulings
register (.docs/DECISIONS.md, R<phase>-<nn>, removed when ruled), the
incident register (.docs/incident-register.md, I-n), the phase register
(.docs/phase-register.md: the owner-faced cost-and-yield ledger,
appended at every gate closure), the phase clock (.docs/phase-clock),
closed plans in .docs/old-phases/. Internal workflow state never lands
in the public repo; git history + plan docs are the record.

## Golden rules (non-negotiable)

1. **Target runtime is Ruby 3.4+ (homebrew, arm64-darwin).** Idiomatic
   modern Ruby within that target. Existing code is modernized only as
   part of a reviewed packet, never as a drive-by.
2. **Dependency policy: pinned set only.** Gems stay pinned `~> x.y`.
   No new dependency without a request for consideration presented
   WITH a pros/cons analysis — never a bare ask.
3. **Irreversible/outward acts are HUMAN actions; routine operations
   are LOOP work.** Owner-only (identity acts): merging PRs into
   `master` (the gate-closing event), `gh release create`, `git tag`,
   OAuth consents, and the listener-facing CLI commands — `podgen
   publish`, `unpublish`, `uploads`, `tweet`, `schedule`, `analytics`
   (Worker deploys), `generate --youtube/--lingq`. Everything
   operational short of that — fetches, fixture recording, regens,
   verification rounds, builds — the loop runs itself, announced and
   verified, once the containing packet is adopted; it never hands the
   owner a runbook of commands it could run (dev-loop doctrine rules
   1–2; blast-radius and ~30-min visibility limits apply). Pushing
   `phase-N` branches is allowed. Owner-only commands are enforced
   twice: settings.json denies and the dispatcher's `CLAUDECODE=1`
   refusal (owner override from the `!` prompt: `PODGEN_OWNER=1`).
   While a production generate holds a run lock (or during the
   16:25–17:10 launchd window) the loop YIELDS: no edits under lib/
   bin/ scripts/, no branch switches or merges — enforced by
   scripts/prod_guard.sh (P2-0).
4. **Never change the frozen domain silently:** RSS/site output
   contracts, the episode guid/basename scheme, and the schemas of
   history.yml, uploads.yml, and `*_timestamps.json`. Breaking these
   disrupts subscribers' apps. Any task that seems to require it stops
   as `blocked: decision-item`.
5. **Machine-readable shapes are frozen contracts:** feed item shape,
   episode file naming, history/uploads/timestamps schemas. Additive
   changes only, with the pinning test updated in the same commit.
6. **No network in tests.** External IO goes through injectable seams
   (`HttpRetryable#with_http_retries`, `Retryable#with_retries`);
   tests inject fakes and recorded fixtures. `test/api/` is the
   explicit exception, gated by `skip_unless_env` and excluded from
   the gate. Fixture refresh is loop-run (`rake fixtures:record`),
   never silently: the recorder refuses empty or truncated bodies.
7. **Minimal diffs.** Smallest behavior-preserving change; no
   reformatting, renaming, or "clean up" beyond the packet's scope.
   Refactors are separate, owner-approved packets.
8. **Secrets from ENV only** (loaded via .env by bin/podgen —
   never Read .env itself). Never read, print, or commit key values;
   error paths must redact.
9. **Pre-existing failing tests are bug signals.** Flag them; never
   skip, dismiss, or treat as background noise.
10. **The dev-loop doctrine binds this project.** Read the dev-loop
   repo's `doctrine.md` (owner-ruled working agreements §1–§27 plus
   §17a/§17b, at origin/main — the local clone lags) and `boards.md`
   at session start for any substantive work; docs/DEV-LOOP.md §9
   carries the podgen reading of the sections that need one.
   Mechanics that bite here: a Bash call containing `git push`,
   `git commit` or `gh pr create` contains NOTHING else; suites run to
   a log (`> log 2>&1; echo exit=$?`) and "green" is read from the
   log, never from a pipe; the gate PR opens ONLY when the phase is
   reviewed and ready for the owner to merge (owner ruling 2026-10-16:
   never as a living document, never as a scratchpad); EVERY
   owner-facing message opens with the phase clock line ("Nh Nm since
   adoption" / "Nh Nm adoption→gate handover", from .docs/phase-clock;
   it is the phase's cost figure, §21); a decision exists for the
   owner only as a minted .docs/DECISIONS.md row — never "awaiting
   approval" in prose (§26); owner-state lines (PR states, drafts) are
   written only from a live query run in the same turn, never copied
   from boards or the loop's own prior messages (§27); the phase
   register is appended at every gate closure; lane briefs state how
   each census was taken (§17a) and batch runners carry timeout /
   budget-stop / first-failure-stop / tail-verification lines (§17b);
   a turn waiting on background work states "independent items
   remaining: N" and N is 0; subagent lanes run on Opus-class models
   (`model: "opus"`), frontier tokens buy judgment.

## Commands

```
bundle exec rake gate                 # pre-commit gate: syntax + lint + unit + offline integration; all green or no commit
bundle exec rake test                 # full suite (incl. keyed API tiers locally)
bundle exec rake test:unit            # fast tier only
bundle exec ruby -Ilib:test test/unit/<file>.rb   # single file
```

## Workflow (every task)

1. **PLAN.** Bug or feature request → respond with a plan, NOT a code
   edit. Read the relevant code first. Bugs: multiple hypotheses,
   evidence, diagnosis. Features: approach, files to touch, tests to
   add, contracts affected. Wait for approval on anything touching >3
   files, any frozen contract, or the frozen domain (rule 4).
2. **TDD.** Failing test before fix: regression test for bugs,
   behavior spec for features; characterization tests pin existing
   behavior BEFORE it is touched. Confirm the test fails for the
   *right* reason, then the minimal diff to green.
3. **Gate before commit.** `bundle exec rake gate` green + the
   self-review checklist below.
4. **Commit on the phase branch** (`phase-N`), conventional message
   referencing the packet ID; tests in the same commit as the code.
   Update the packet's status + worklog line in .docs/pXX-plan.md in
   the same sitting.
   Push the phase branch and watch CI (`gh run list`) — CI is the
   authority over the local toolchain.
5. **Review before handoff.** Before a PR goes to the owner, run CRPR:
   spawn a worktree agent (`isolation: "worktree"`) running the `/cr`
   skill; fix all BLOCKERs and WARNINGs; re-review until APPROVED.
   On APPROVED, `git update-ref refs/cr/reviewed HEAD`.
6. **STOP at gates.** Phase boundaries end the turn with a runbook
   handoff (numbered steps, one command each, EXPECT lines) and an
   open PR — the owner merges. Never mark a phase done.
7. If the change invalidates an ARCHITECTURE.md entry, update it in
   the same commit. "Document" = update CLAUDE.md and README.md.

### Self-review checklist
- [ ] Ruby 3.4+ compatible; no unapproved dependencies
- [ ] tests added/updated and green; no network in gate-tier tests
- [ ] contracts unchanged or additive + pinning test in the same commit
- [ ] nothing in the frozen domain changed (or explicitly flagged)
- [ ] no secrets in code, logs, fixtures, or error messages
- [ ] diff is minimal; unrelated code untouched
- [ ] success claims cite an outcome-level check (what would a
      listener/user see?), not only signals the system emits
- [ ] CI green on the pushed head before calling a packet done

### Verification discipline (binding)
1. **Outcome-first.** No "done / green / live" claim without a check
   at the outermost user-visible surface (the feed a podcast app
   parses, the served site page, the played mp3) against a reference
   INDEPENDENT of the system under test — content dates vs wall
   clock, never self-minted stamps.
2. **Contradiction protocol.** Owner observation contradicting
   telemetry = telemetry blind spot; reproduce at THEIR surface
   first; never re-assert health from an instrument already
   contradicted once.
3. **Decommissioning inventory.** Before retiring any process,
   enumerate every duty it performed and map each to a successor;
   unmapped duties become decision items.
4. **Content-progress invariants.** Every scheduled producer
   (launchd-scheduled generates/publishes) carries a machine-checked
   invariant on its OUTPUT's progress, not its execution.
5. **Specific verification asks.** Owner-facing verification requests
   carry exact command lines and files, plus what good/bad looks
   like — never a bare "take a look".
6. **Commit owner-session data immediately** after every owner
   apply/edit (history.yml, uploads.yml, guidelines edits made in
   session) — cheap insurance against agent-wipe incidents.

## Code style

- Single responsibility per class/method.
- Shell: `Open3.capture3`. Paths: `File.join` + `__dir__`-relative.
  `require_relative` everywhere.
- Atomic writes (temp + rename) for history/cache files.
- TTS split order: paragraph → sentence → comma → whitespace → UTF-8
  char boundary.

## Testing conventions

- Minitest. Tiers: `test/unit/` (no I/O, in the gate),
  `test/integration/` (offline subset in the gate), `test/api/`
  (keyed, `skip_unless_env`, never in the gate).
- Naming: `test_<method>_<scenario>_<outcome>`. Structure:
  Arrange → Act → Assert.
- Fixtures are recorded real responses, trimmed to minimum.

## Git conventions

- All work on phase branches (`phase-N`) pushed to origin; `master`
  is owner-merged via PR at gates. No agent pushes to `master`, no
  force pushes, no history rewrites on published branches, no tags
  (tags/releases are gate actions, owner-run).
- Conventional commits (`feat:`/`fix:`/`test:`/`refactor:`/`docs:`/
  `chore:`) referencing packet IDs; imperative subject ≤ 72 chars;
  body explains WHY.
- One logical change per commit; tests with the code. Never commit
  .env, output/, logs/, or podcast content directories.
- No AI branding on any public surface (owner ruling 2026-10-16,
  doctrine §13): no `Co-Authored-By` assistant trailers on commits, no
  "generated with" footers on PR bodies, no authorship attribution to
  an assistant anywhere. Technical references to the API vendor or a
  model id (class names, model registry, docs) are not branding.

## Workflow notes

- Screenshots/pics: check `~/Desktop` for recent .png files sorted
  by date.

## Current phase

Gate 0 CLOSED 2026-09-02 (PR #1, merge 4298988). Gate 1 CLOSED 2026-10-11
(PR #2, merge 6d869e4). Gate 2 CLOSED 2026-10-12 08:50 (PR #3, merge
494c000). Gate 3 CLOSED 2026-10-12 11:45 (PR #4, merge 35592dd). Gate 4
CLOSED 2026-10-12 12:55 (PR #5, merge 8e454c6 — the dry-up). Gate 5
CLOSED 2026-10-12 18:25 (PR #6, merge e3106e2 — correctness and cost
sweep). Gate 6 CLOSED
2026-10-14 21:40 (PR #7, merge 2aad556 — spend measured, observability,
docs refresh, refill, plus the P6-7/P6-8 hotfixes). Gate 7 CLOSED 2026-10-16
20:05 (PR #8, merge dedd365 — publication observability and YouTube
hardening). Gate 8 CLOSED 2026-10-28
15:40 (PR #10, merge 1d3da37 — quality guards, diagnosis, test
authority; phase clock 56m). Gate 9 CLOSED 2026-10-28 18:04 (PR #11,
merge a177a33 — vocabulary didactics: ledger, key words, level bands,
gloss cache, grouped section, vocab-health measurement, revocab ranges;
phase clock 1h 42m). Gate 10 CLOSED 2026-10-29 14:59 (PR #12, merge
82e79e3 — resilience of the scheduled run and a truthful board: re-post
guard at selection, the intended timeout on every Claude call,
caffeinate + bounded preflight, upload progress read from the batch
log, LingQ generate path, placeholder-key lint; phase clock 47m).
Phase 11 (listening archive of untrimmed source audio and rejected
candidates; 404 source URLs excluded in-run; YouTube token rejection
logged and consent-age WARN; Exa network errors retried; uncounted
content failures counted; trim-prompt re-ask) AT GATE 11 — adopted
2026-10-29 15:40, all packets landed, CRPR APPROVED (refs/cr/reviewed =
8e85c7f); gate PR open, the owner merges. R9-02, R10-01, R10-02 on the
register; I-11 open (YouTube consent expires every 7 days while the
OAuth app is in testing). Update this line at each gate.
