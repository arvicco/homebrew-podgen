# Worklog

One dense paragraph per completed packet, newest first:
date · packet · commit · notes (what changed, why, evidence, catches).
Incidents get their own entries: what happened, root cause, the
durable fix, the lesson now enforced.

---

2026-09-01 · rulings batch · (this commit) · Owner ruled the three
standing registry items. D0-p: stray worktree commit 6dd5ba8
discarded (worktree + branch removed), merged
refactor/dry-and-test-coverage pruned local + origin — repo is down
to master + phase-0 everywhere. D0-o: dead-code batch KEPT documented,
periodic-review item Q-13. D0-c…D0-n: formulated as self-contained
queue items Q-01…Q-12 in NEW docs/WORK-QUEUE.md (tracked; each with
problem, first-failing-test sketch, acceptance, tier suggestion;
fix packets get cut from the queue when scheduled). Registry now
holds only the formal M0-3 sign-off. M00-7 owner-confirmed in real
use, closed.

2026-08-31 · M00-7 · (this commit) · Preview re-wired Quick Look →
QuickTime Player after the owner's real-run check on M00-6 found
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

2026-08-30 · M00-6 · (this commit) · ask-trim preview via Quick Look
(D0-r option B, owner-trialled on a real episode and approved before
any code changed — lesson from M00-5 applied). `open`→Music replaced
by background `qlmanage -p`: positional scrubbing + min:sec readout,
zero library imports, prompts live while the preview is open, TERM on
prompt completion and on exclude (ensure block). TDD: 3 tests red
(NoMethodError / no spawn) then green; existing ask_trim
characterization tests repointed from the :system stub to the new
:start_preview seam. Gate 2958+50 green. Music pollution class closed:
nothing is imported anymore, so cleanup options A/D unnecessary.

2026-08-30 · M00-5 REVERTED · (this commit) · ffplay ask-trim preview
(5bfca6e) rejected by owner within hours: ffplay's fixed-step seeking
and bare window are not usable for the trial-and-error hunt for
cut-off points — Apple Music's transport is the requirement, the
pollution is the bug. Lesson: the D0-q proposal optimized what I
could measure (no library imports, seconds readout) over the owner's
actual workflow (fast interactive scrubbing); the owner check in the
acceptance criteria fired exactly as designed. `open`→Music restored;
mitigation research filed as D0-r (options: post-preview AppleScript
auto-cleanup inside --ask-trim; Quick Look zero-import preview;
periodic sweep). ttt.mp3 deletion stands (approved separately).

2026-08-25 · M00-4 · (this commit) · Freshness invariant:
Validators::FreshnessValidator (newest content date vs wall clock,
cadence = median history gap, OLD warning past 2× median) wired into
PodcastValidator (array + check_freshness). TDD: 7 unit tests failed
for the right reason first. The new check immediately caught the
test_stats_validate "clean podcast" fixture rotting (hard-coded
2026-01 dates) — fixture moved to relative dates. Outcome check on
real data: lahko_noc flags OLD (newest 2026-03-21, 157d, daily
cadence); bajke/basnie/cuentos/fiabe/fulgur_news validate fresh;
ruby_world correctly reports cannot-infer-cadence. Gate green.

2026-08-25 · M00-3 · 1c6f87d · Source registry: 14 hard-coded service
endpoints registered with probe URLs + expectations; drift test in
the offline gate (red on seeded unregistered host, green on HEAD);
IGNORED_HOSTS allowlist for namespace/display URLs; rake health
owner-run probe — 14/14 OK live (elevenlabs probe URL corrected
after first run). Per-podcast RSS feeds ruled out of registry scope
(config, not hard-coded).

2026-08-25 · M00-1 + M00-2 · (this commit) · Phase 00 opened per
owner ruling (conventions before Phase 0 continues). M00-1: gitignored
.docs/ workspace created; TOOL-REVIEW.md relocated there;
.docs/DECISIONS.md registry seeded (D0-p stray-worktree salvage, D0-o,
D0-c…D0-n, M0-3 sign-off — newest first, removed when ruled); dev-loop
plugin skill+templates updated in its own repo (commit 34a4994) to
encode the convention. M00-2: CLAUDE.md verification discipline
extended to the skill's six items (specific asks; commit
owner-session data); DEV-LOOP.md §4 gains the ring-for-owner alarm
step. M0-3 status normalized to blocked: decision-item. Docs-only in
podgen; gate green.

2026-07-27 · M0-3 (memo drafted) · (this commit) · Full-lib inventory
via four parallel read-only agents (~130 files), synthesized into
docs/TOOL-REVIEW.md: 12 suspected-bug decision items (D0-c…D0-n), a
10-item dead-code batch (D0-o), 8 duplication/divergence risks, the
frozen-contract inventory seeding M0-5, and a ranked 16-entry
pure-logic list seeding M0-4. Coverage headline: nearly every module
already has a dedicated unit test; gaps are publisher_shared,
usage_logger, openai_client, language_names, and the four network
sources (live-API tests only). Packet stays in-progress until owner
sign-off per acceptance.

2026-07-27 · M0-2 · (this commit) · Gate wired into CI: rake gate now
also runs standardrb (was CI-only, so local gate and CI agree — it
immediately caught a quote-style violation in the gate task itself);
ci.yml triggers on phase-* pushes and collapses its three test steps
into one `bundle exec rake gate` step. COVERAGE=1 scope widened from
unit-only to the whole gate (simplecov now sees offline integration
too). Evidence: gate green locally (305 files syntax-OK, lint clean,
2942+48 runs); CI on pushed head checked below.

2026-07-27 · M0-1 · (this commit) · Dev-loop migration: instantiated
CLAUDE.md (arbot-style golden rules; CRPR retained as pre-PR review;
git model moved to phase branches + owner-merged PRs per D0-a),
docs/DEV-LOOP.md, docs/BACKLOG.md (full brownfield Phase 0 per owner
ruling), docs/WORKLOG.md; added `rake gate` (syntax check over
lib/bin/test + test:unit + test:integration_offline). Evidence: gate
run green locally before commit.
