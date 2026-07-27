# Architecture

How the finance layer is put together, and why each piece is the way it is. Object and field names here are the generic re-authored ones used throughout this repository.

## 1. The delivery chain (pre-existing foundation)

The finance layer sits on top of a sales-to-delivery chain that the org already had:

```
Account → Opportunity → Project → Deliverable → Line Item
```

- Winning an Opportunity auto-creates a **Project**; each product sold becomes a **Deliverable**; each unit of quantity becomes a **Line Item**. All of this is Flow-driven.
- The chain below Opportunity is **master-detail all the way down**, which is what makes native roll-up summaries possible per level — and what *exhausts* the platform's 3-level master-detail ceiling at the Line Item. That single fact shapes half the design decisions below.

## 2. Invoicing: a many-to-many junction

Real invoices rarely map one-to-one to deliverables: one invoice covers many lines, one line is billed across many invoices. So:

- **Invoice** (auto-number, Private OWD): account (required), opportunity (required, delete-restricted, lookup-filtered to the account's deals), amount, dates, status, external id for future ERP reconciliation.
- **Allocation** (junction): **master-detail to Invoice** (so invoice-side roll-ups are native), **lookup to Line Item** (master-detail is impossible — the ceiling), allocated amount, collected amount.

Guardrails as validation rules: collected ≤ allocated per line, no negative amounts, an allocation cannot push the invoice past its own amount (plus a backstop on the invoice itself, which also blocks lowering an invoice below what is already allocated). A formula shows the unallocated remainder — zero means fully allocated.

### Roll-up mechanics on the lookup side

A lookup can't carry a roll-up summary, so the Line Item's `Invoiced Amount` and `Collected Amount` are **flow-maintained**:

- A **subflow** recomputes both sums for a given line.
- An **after-save flow** on Allocation (create/update, handles reparenting) and a **before-delete flow** (excludes the row being deleted) invoke it.
- Measured bulk safety: ~3 SOQL / 2 DML per 200-record batch — Flow auto-bulkifies subflow operations across interviews.

**Known limitation, consciously accepted:** deleting *multiple* allocations of the same line in one DML overstates that line, because each delete interview only excludes its own row. Real-time correctness would require an after-delete Apex trigger; instead a **schedule-triggered nightly reconciliation flow** re-runs the subflow across every line carrying a value. Declarative self-healing beat another Apex dependency for an interim system.

### Automatic invoice status

A **before-save flow on Invoice** sets Paid (collected ≥ amount) and Partially Paid (> 0). The elegant part: **roll-up summary recalculation re-fires the parent's before-save automation and validation rules** — so editing an allocation's collected amount updates the invoice's status in the same transaction, with no extra plumbing. Draft, Sent, and Void stay manual; status is informational and feeds no roll-up.

## 3. The Revenue Position

Eight figures on every deal, computed from the chain:

| Figure | Definition |
|---|---|
| Total Delivered | Σ value of fully delivered deliverables |
| Total Recognized | Σ value of delivered line items (line-grain earnings) |
| Total Invoiced | Σ line-item invoiced amounts |
| Total Paid | Σ line-item collected amounts |
| Accounts Receivable | max(0, Invoiced − Paid) |
| Unbilled | max(0, Recognized − Invoiced) |
| Deferred Revenue | max(0, Invoiced − Recognized) |
| Remaining Revenue | max(0, Contract − Recognized) |

Delivered vs Recognized coexist on purpose: one is deliverable-grain (operational), one is line-grain (financial). During parallel-run they let Finance reconcile the old and new models tile by tile.

## 4. Planned billing schedule

A lightweight **Billing Milestone** object per deal mirrors the SOW's billing plan: milestone description, expected amount, expected date, status. Design points:

- **Amount-native, not percentage-native.** Real SOWs write "invoice $50,000 on execution", not "invoice 40%". Percentages are a trivial cutover-time computation; amounts are the source of truth. (This replaced an earlier percent model — see the percent gotcha in the engineering notes.)
- Milestones must **reconcile to the contract amount**. A flow-maintained total on the deal plus a formula flag light up any deal whose plan exists but doesn't sum to the contract; a finance list view queues the mismatches.
- Deliberately **not** connected to deliverables or invoices: it is the plan, not the actuals. Resisting the urge to build a plan-vs-actuals engine kept the object clean and the migration story simple.

## 5. Revenue recognition engine (the one Apex exception)

Setting a **Recognition Start Date** on a deliverable triggers an after-save flow that calls an invocable Apex service, which generates the deliverable's **Revenue Schedule** rows:

- Straight-line over 12 months at a **daily period rate** — a mid-month start produces day-prorated partial first and final periods (13 rows), a month-start produces 12 clean rows.
- Rounding differences land in the **final period**, and the schedule **always sums exactly** to the deliverable's value — asserted by the test suite.
- Rows carry audit fields (calculation method and version, run id, source amount and dates, period type, is-partial) so a future ERP migration can trust and trace every row.
- Regeneration on date change is idempotent: the engine replaces the deliverable's schedule atomically.

Why Apex here and Flow everywhere else: exact-sum guarantees with per-day proration require iteration, rounding control, and deterministic remainders — expressible in Flow only as a fragile lattice of formulas. One well-tested class beat that trade.

## 6. Delivery tracking and the all-or-nothing roll-up

- Marking a line item Delivered stamps its delivery date (a loop-safe pair of before-save flows syncs status ↔ date in both directions) and recognizes its value.
- A deliverable flips to **Delivered** only when *delivered units = quantity*, via a flow on the deliverable that fires when its delivered-units roll-up recalculates. Partial delivery leaves deliverable status untouched — money moves at line grain regardless.
- The deliverable's **Expected Delivery Date is a formula reading the product line's date** on the deal. One consequence worth knowing: the "fill in delivery dates" data task lives with whoever owns the deal's product lines, not with delivery — surfacing that early saved a cross-team misunderstanding.

## 7. Stage-gate governance

Pipeline stages are gated by validation rules, not approvals: reviews and document checkboxes must be set before a deal can enter the gated stage. Two hard-won details:

- Gates must fire on **records created directly at the gated stage**, not just on transitions — `ISCHANGED()` is always false on create, so every gate needs `OR(ISNEW(), ISCHANGED(...))`. This exact bug was found and fixed **four separate times** in this org (three flows, one validation rule) — see the engineering notes.
- State-based rules (no ISCHANGED at all) catch stage-skipping: a deal jumping over the gated stage still hits a rule that checks *being at or beyond* the gate.

## 8. Reporting layer

- Custom report types expose the full 4-level chain. **Report types do not auto-add new fields** — every new finance field had to be added to the report type definition explicitly.
- Metric tiles source **deal-grain summary reports** (won deals, value > 0) rather than schedule-row sums — immune to per-row double counting.
- The dashboard was recreated in production **via the Analytics REST API** after the Metadata API refused to move the originals (see the runbook patterns). Every tile was then audited: open the source report, run the equivalent SOQL, match to the cent. That audit caught a tile aggregating a backward-looking field on a forward-looking chart — inherited from the demo config and invisible until real data arrived.

## 9. Interim-by-design

The whole layer is scoped to management visibility, not audit-grade accounting (the ERP owns that). Composability rules honored throughout:

- Each capability = own objects + own flows + own permission set entries; switch-off is clean.
- External ids on financial records for future reconciliation.
- No customization of the sales pipeline beyond the gates it already had.
- The catalog, terms, and financial data all load/export through documented, re-runnable scripts.
