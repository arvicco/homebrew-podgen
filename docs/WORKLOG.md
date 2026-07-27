# Worklog

One dense paragraph per completed packet, newest first:
date · packet · commit · notes (what changed, why, evidence, catches).
Incidents get their own entries: what happened, root cause, the
durable fix, the lesson now enforced.

---

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
