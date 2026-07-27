# Runbook Patterns

Operational patterns used to run this build safely in a live production org. Everything here is client-agnostic and reusable.

## 1. The gated data load

Every production data operation follows the same ladder:

1. **Back up first** — export the affected records (all relevant fields) to CSV; for metadata changes, save the pre-change definitions as rollback artifacts.
2. **Dry-run** — a read-only pass that resolves every target record and prints exactly what would change (matched / would-override / not-found). No dry-run, no load.
3. **Small batch** — apply to a handful of records, verify in the org (not in the tool output).
4. **The rest** — then verify with independent queries: counts, distributions, spot checks.
5. **One operation at a time** — deletes, updates, and inserts never share a step.

## 2. Validation-rule lift / apply / restore

When a legitimate backfill collides with validation rules (records that predate the rules can't be re-saved), the pattern is a tightly-scoped lift:

1. Query the rules via Tooling, save each rule's full `Metadata` JSON (rollback artifact + patch source).
2. `PATCH` each rule with `active: false` (send the **complete** Metadata back — partial patches clobber).
3. Run the load. 4. `PATCH` back to `active: true`. 5. Verify every rule is active again with a query, and keep the window seconds-to-minutes wide, not hours.

The same GET-modify-PATCH round-trip works for activating flows that land as Draft (`FlowDefinition.activeVersionNumber`) and for editing picklist value sets in place (`CustomField.Metadata.valueSet` — including dependent-picklist `valueSettings`).

## 3. Analytics REST as the escape hatch

When reports/dashboards won't move through the Metadata API (retired report types, "report definition is obsolete", empty retrieve errors), the Analytics REST API builds them from intent:

- `POST /services/data/vXX.0/analytics/reports` accepts a full `reportMetadata` payload (report type, columns, groupings, aggregates, filters, scope).
- `POST /analytics/dashboards` accepts the describe-shaped JSON: fetch the source dashboard's describe, remap `reportId`s to the new org, strip stale visualization props on overridden tiles, post.
- Execute a report headlessly with `GET /analytics/reports/<id>?includeDetails=false` to verify totals.

Two payload traps: grouped fields can't repeat in `detailColumns`, and aggregate names must exist in the target report (`s!FieldName`). The generalized builder scripts live in [`scripts/analytics/`](../scripts/analytics/).

## 4. Tile-by-tile dashboard audits

A dashboard "looking right" proves nothing. The audit that catches real defects:

1. For each tile, open the **source report definition** via the API: report type, filters, the exact aggregate bound to the tile.
2. Write the equivalent SOQL independently; match the report's total **to the cent**.
3. Explain every zero: is it correct-zero (no data yet) or broken-zero (wrong binding)?
4. Check tile semantics against the metric's *name* — this is what caught a forward-looking chart aggregating a backward-looking field, a defect inherited from the demo config that produced plausible zeros.

## 5. Sandbox-first destructive experiments

Any operation whose data effects are undocumented gets rehearsed on a refreshed sandbox first — a refresh preserves production record IDs, so **ID-based scripts replay verbatim** against the copy. Pattern: run the experiment on the sandbox, measure (row counts before/after), and only then run it in production, expecting identical results. This turned "does unchecking product scheduling delete existing schedule rows?" from a gamble into a measured no.

## 6. Self-cleaning in-production smoke tests

Post-deploy verification in production uses anonymous Apex scripts that create clearly-marked test data, assert the full lifecycle (create → allocate → collect → auto-status → guardrail blocks), and **delete everything in a `finally` block** — so a failed assertion still cleans up. The scripts live in the repo and re-run in seconds, which makes "re-verify today" cheap enough to actually do before telling anyone it works.

## 7. The anonymization scrub

For a public repo derived from client work: re-author every artifact from intent (never copy-and-scrub), then enforce a **denylist grep** — client names, people, customer names, domains, org IDs, real amounts — that must return zero hits before any push. The check lives at [`scripts/scrub-check.sh`](../scripts/scrub-check.sh) and takes seconds; run it in a pre-push hook so it can't be forgotten.
