# Engineering Notes — the gotcha catalog

Platform behaviors that cost real hours on this build. Each entry: the symptom, the root cause, the pattern that fixes it. All verified on API v66 era orgs; a few are documented, several are not.

## 1. `ISCHANGED()` is always false on record creation

**Symptom:** an automation "randomly" doesn't run; records created *with* the triggering value already set never process. Weeks later someone asks why records are missing from a report.

**Cause:** entry conditions like `Field = TRUE AND ISCHANGED(Field)` (or a flow's "Is Changed" filter) never match on insert.

**Fix pattern:** `AND(OR(ISNEW(), ISCHANGED(Field)), Field)` — in flows as an entry formula, in validation rules verbatim. This bug was found **four times** in one org: three date-stamping flows and one stage-gate validation rule. Once you see it, audit every automation with an Is-Changed entry.

## 2. Percent fields: decimal in formulas, raw in Flow

A percent field is `1.0` for 100% inside **formulas and validation rules**, but `100` inside **Flow**. So a VR `Percent__c > 100` can never fire (120% evaluates as 1.2), while a flow summing three 33.3% children gets 99.9. A percent rolled up by flow into a Number field then compares "normally" (`= 100`). Mixed-context percent logic is a trap; prefer amount-native models where money is involved.

## 3. Flows can deploy as Draft in production

The same Metadata API deploy that activates flows in sandboxes can land them **Draft** in production (org-dependent). Post-deploy, activate via Tooling:

```
PATCH /tooling/sobjects/FlowDefinition/<id>  {"Metadata": {"activeVersionNumber": N}}
```

Always verify `Flow.Status = 'Active'` after production deploys; don't trust the deploy summary.

## 4. Obsolete flow versions block field deletion

Re-pointing a record-triggered flow (keep the API name, change the field it reads) leaves the **prior version Obsolete but still referencing the old field**. Deleting that field then fails with a Flow-version dependency error. Fix: delete the obsolete Flow *version* records via Tooling (inactive versions are deletable), then delete the field.

## 5. Roll-up recalculation re-fires parent automation

When a child edit changes a roll-up summary, the parent's **before-save flows and validation rules run again**. This is a feature if you design for it (automatic status transitions with zero plumbing) and a bug if you don't (unexpected VR blocks on child edits). Design for it.

## 6. Delete-triggered flows can't see the whole batch

A before-delete flow interview sees only its own record — it cannot re-query "the other rows being deleted", and scheduled/async paths aren't available on delete triggers. Consequence: cross-row consistency on multi-delete cannot be maintained declaratively in real time. Options: an after-delete Apex trigger, or (chosen here) a schedule-triggered nightly reconciliation flow that recomputes from scratch.

## 7. The master-detail ceiling shapes junctions

Master-detail depth maxes out at 3 levels. A junction whose "many" side sits at the bottom of such a chain **must** use a lookup — which means no native roll-ups on that side, which means flow-based roll-ups, which means owning their edge cases (see #6). Budget for that chain of consequences when you place a junction low in a hierarchy.

## 8. Lookup filters and predefined values run out of road quickly

- Lookup filters can't traverse deep relationship paths, and a filter's `$Source` can't reference a formula field.
- Create-type quick actions **cannot predefine a lookup from a formula** — deploy fails with a type mismatch (formula yields Text, field wants Lookup).
- A universally required field **cannot be auto-filled by a before-save flow on a standard create form** — required-field validation runs before flows.

When all three walls close in, the answer is a **screen flow behind a quick action**: it derives the related values itself and inserts a complete record.

## 9. FLS quirks that read as missing fields

- "No such column" in anonymous Apex or the API right after deploying a field usually means **no field-level security for the running user** — metadata-deployed fields grant no FLS by default. Assign the permission set first.
- You **cannot add FLS for a universally required field** to a permission set — the deploy fails. Required fields get access via object CRED; keep them out of `<fieldPermissions>`.

## 10. Multi-component deploys roll back atomically — and quietly

One component's failure reverts the whole batch, and the deploy summary may still list already-processed members under "successes". After any partial failure, re-verify every component of the batch in the org, then redeploy the reverted ones.

## 11. Describe caches lie; the Tooling API doesn't

- CLI describe caches can report a live field as absent. Confirm field existence via `FieldDefinition` by API name.
- `sobject describe` returns null for formula bodies and roll-up definitions — read them via Tooling `CustomField.Metadata`.
- `FieldDefinition` itself can serve stale rows for **brand-new objects** (showed 5 of 17 fields right after a deploy). The authoritative check is Tooling `CustomField` keyed by the object's real ID — and beware duplicate/phantom `CustomObject` rows with the same developer name choosing the wrong one for you.

## 12. Product SKU uniqueness is platform-enforced

`StockKeepingUnit` enforces org-wide uniqueness (DUPLICATE_VALUE on collision) — and it's a *different field* from `ProductCode`. Realigning a SKU series is therefore an ordering problem: **free a SKU before another product takes it**, within one transaction if you order the updates correctly, or in a pre-pass that clears superseded values.

## 13. Product scheduling has teeth

- Default revenue/quantity schedules on a product **auto-create schedule rows on every deal** that adds it — silently.
- Disabling a scheduling type **org-wide deletes all schedule data of that type**. Product-level unchecking, by contrast, preserves existing rows — verified empirically on a sandbox copy before touching production (rows before = rows after).
- Unchecking the product-level flags throws FIELD_INTEGRITY_EXCEPTION unless the default schedule fields are **nulled in the same update**.

## 14. Bulk API details that fail whole jobs

- CSVs must use **LF line endings**; Python's csv module writes CRLF by default and the job fails instantly with a LineEnding error, zero records processed.
- Trust the **job result counts** (`numberRecordsProcessed` / `Failed`), never the CLI spinner — it truncates and can read as success.
- Updates write only the columns present: omit a column to leave the field alone; an **empty cell nulls it**.

## 15. macOS narrow no-break space

macOS screenshot filenames contain a **narrow no-break space (U+202F)** before "AM/PM". It renders as a normal space in every terminal listing and breaks every hardcoded path. Glob for the prefix; never type the space.

## 16. Report types don't grow with your objects

New fields on an object **do not appear in existing custom report types** — every column must be added to the report type definition explicitly, in every org. Symptom: Analytics API rejects a column that visibly exists on the object.
