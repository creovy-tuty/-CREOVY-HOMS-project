# Step 10A reporting contract

The Web and Flutter reporting repositories are read-only projections over the existing workspace-owned collections. They do not write financial records, maintain a reporting collection, or use a second ledger. The caller supplies a workspace ID, every list query constrains `workspaceId`, and Firestore membership rules remain the authority for access. The direct tenant lookup also checks its workspace. No Firebase integration or deployment is part of this step.

## Time and filters

`from` and `through` are optional inclusive **Asia/Kolkata calendar days**; queries use the start of `from` and the exclusive start of the day after `through`. Firestore timestamps remain timestamps. `YYYY-MM` is the stable internal trend key; presentation can later use `DD/MM/YYYY`. With no date bounds, the report covers all available source records subject to the client read ceiling. The date selector applies to `rentDues.dueDate` for due-based values, `rentPayments.paymentDate` for rent cash, `propertyBills.billDate` for raised/current bill balances, `propertyBillPayments.paymentDate` for bill cash, `propertyExpenses.expenseDate` for expenses, and `securityDepositTransactions.transactionDate` for deposit cash.

Property and unit filters apply where a source has those relationships. Tenant and agreement filters apply to rent and deposits; bill type applies to bills; expense category applies to expenses; rent status applies to dues and associated payment rows. Specialized reports ignore unrelated filters. Portfolio, property-performance, and monthly net-cash results reject tenant/agreement/rent-status/expense-category filters: property expenses cannot be accurately allocated to those scopes. A bill-type filter in the portfolio affects only its bills section. A filtered occupancy inventory remains property/unit inventory; tenant/agreement filters affect its agreement counts, not which units exist or whether an active agreement occupies them.

## Metric definitions

| Result | Definition |
| --- | --- |
| Expected rent | Sum `rentAmountPaise` of selected dues whose due date is within the due-date range. |
| Rent collected | Sum individual `rentPayments.amountPaise` with payment date in the cash-date range; partial payments remain separate transactions. |
| Collected against expected | Sum cash-date-selected payment transactions linked by `rentDueId` to selected dues. |
| Rent outstanding | Sum current `balancePaise` for selected dues. |
| Rent overdue | Sum positive current due balances with `dueDate` before today's Asia/Kolkata midnight. A partially paid overdue due contributes its remaining balance even if its stored status is `partial`. |
| Collection rate | `collectedAgainstExpectedPaise / expectedRentPaise * 100`, rounded to two percentage decimals; zero when expected is zero. The numerator uses the selected payment-date window, not all-time receipts against the selected dues. |
| Property expenses | Sum/count of `propertyExpenses` and amount groups by category, property, and non-null unit. Bills are excluded. |
| Bills raised / outstanding / overdue | For bills selected by `billDate`: sum original `amountPaise`, current `balancePaise`, and current balance past the due date, respectively. |
| Bills paid | Sum individual `propertyBillPayments` in the selected payment-date range, grouped by `billType`. It is not restricted to bills raised in the same range. |
| Deposit agreed | Current contractual `securityDepositAgreedPaise` on non-draft/non-cancelled agreements, including agreements with no deposit movement yet. |
| Deposit received / refunded | Sum individual deposit transactions by type and transaction date. |
| Deposit currently held | Sum authoritative current `securityDeposits.heldBalancePaise` summaries. This is a stock value, not a dated cash flow. |
| Net property cash flow | `rentCollectedPaise - totalExpensesPaise`. V1 deliberately excludes bills/taxes and both deposit receipts and refunds. |

All money values are integer INR paise, checked against the cross-platform safe-integer range. Rates alone use floating-point percentages with safe zero denominators. Due/bill balances, deposit held, agreement amounts, and occupancy are **current snapshots**, even when a date range is selected. The repositories do not reconstruct historic balances or occupancy as of an earlier date. Separate collection reads are not one atomic snapshot; concurrent source changes can create short-lived cross-section differences. Rent expected also depends on Step 6A dues having been materialized for the period.

## Occupancy, history and series

Current `rentalAgreements.status == active` is the occupancy authority. Rentable inventory excludes units whose status is `inactive` or `maintenance`; maintenance/inactive counts are returned separately. Occupied is the count of rentable units with an active agreement; vacant is rentable minus occupied. A unit flagged occupied without an active agreement is not counted occupied. Occupancy rate is occupied / rentable, or zero with no rentable inventory. Active tenants are distinct tenant IDs among active agreements; active, upcoming, and ended agreement counts are separate. Tenant rent history returns selected due and payment rows plus current outstanding. The agreement-history entry point verifies the workspace-owned agreement and reuses tenant history with an `agreementId` filter. No tenant scoring is produced.

Property performance returns one row per selected property with rent, expenses, net cash, and occupancy; it does not rank or score properties. Monthly trend groups expected rent by due `periodKey` and actual rent/expense cash by the Asia/Kolkata month of their timestamps. Missing months may be filled with zero **only in returned data**; no zero financial record is written. The trend is capped at 120 months.

## Query and export boundaries

Each source query is workspace-scoped and uses the date field plus an indexed property, unit, tenant, agreement, category, or type dimension where available. Other dimensions are applied to the bounded workspace result in memory. Each source query requests at most 3,001 documents and fails if more than 3,000 would be required; it never silently reports a partial total. Context reads (properties, units, agreements, deposit summaries) use the same ceiling. This is deliberately a bounded client-side V1 engine, not a large-workspace aggregation solution. Large workspaces need a trusted server aggregation design in a later step; do not raise the cap without considering read cost, pagination consistency, and security. Composite indexes are declared in `firebase/firestore.indexes.json`; they are not deployed here. Existing membership rules are unchanged.

Flat, typed result rows and integer-paize groups are ready for future Web print/PDF/CSV/Excel and Android share/export adapters. No UI, charts, exports, Cloud Functions, scheduled reports, forecasts, notifications, or AI insights are implemented in Step 10A.

## Step 10B presentation

Web Reports is reached from **Insights → Reports**; Android Reports is reached from the existing **More** screen without changing bottom navigation. Both default to the current Asia/Kolkata month and apply date/property/unit filters only after confirmation. Rent status affects the rent section, not the portfolio net-cash metric. A read-only rent-due breakdown projection supplies current due amounts, paid-to-date balances, status, and workspace-owned property/unit/tenant names for drill-down; it does not create financial records. The Web table and Android cards distinguish paid-to-date due balances from payment-date-period cash totals.

Monthly visuals use existing report result values and only scale bar lengths for display. They require no chart package or dependency installation; they are compact comparative bars rather than axis-based financial plots. This is the intentional dependency-free chart limitation. The UI shows the 3,000-row/source refusal as a request to narrow date or property filters and never presents a partial report. Print, PDF, CSV/Excel, and share remain unavailable; no export controls pretend to work. Historical stock/as-of limitations documented above still apply.
