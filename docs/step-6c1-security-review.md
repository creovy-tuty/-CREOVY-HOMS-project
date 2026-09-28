# Step 6C-1 financial-record security review

This is a source-level review, not an emulator test, Rules compiler check, deployment, or production security certification. The Firestore database edition was not queried because this step prohibits validation/Firebase commands. The existing project uses the standard Firebase client SDKs and `firebase/firestore.rules` configuration.

## Data and query assumptions

- `rentPayments/{paymentId}` uses one stable UUID per intended payment.
- `receipts/{paymentId}` and `tenantLedger/rent_payment_{paymentId}` are created only with that new payment and its due update in one transaction.
- `receiptNumber = CRV-R-{paymentId}` uses the complete UUID, not a local counter or truncated token.
- Receipt and ledger fields are immutable snapshots. Monetary values are positive integer paise and match the payment. Payment/transaction dates are timestamps; audit creation uses server time.
- Receipt tenant/property/unit names are read in the same transaction and checked against those workspace-owned documents by rules. Missing source documents reject a new payment bundle.
- Client queries are scoped by `workspaceId`: receipt by deterministic payment ID, receipt by tenant/number, ledger by tenant/agreement ordered by `transactionDate`. Future period and workspace chronology indexes are prepared but not queried by current UI.

## Manual adversarial review

| Attempt | Expected rule outcome |
| --- | --- |
| Anonymous or other-workspace read/write | Denied by Auth and active membership checks. |
| Viewer creates financial record | Denied; only owner, manager, accountant may create. |
| Standalone receipt/ledger for an existing payment | Denied because the source payment must be absent before and present after the same commit. Controlled historical backfill must use trusted tooling. |
| Receipt/ledger with changed workspace, amount, relationship, mode, actor, or date | Denied by exact match to the new payment and authenticated UID. |
| Duplicate receipt number from a different payment | Denied by deterministic full payment-ID number and required document-ID relationship. |
| Add extra fields, invalid entry type, or oversized reference/description | Denied by exact field lists, type checks, value constraints, and length limits. |
| Edit/delete a receipt or ledger entry | Denied. |
| Create a payment without both derived records | Denied by `validPaymentBundle` and cross-document post-commit checks. |
| Retry a committed payment ID | Existing payment returned; no new financial writes. Historical payments remain unchanged. |
| Forge a due-only paid-total increase or multiple same-amount payment bundles against one due delta | **Not fully preventable** with the current client-only due schema/rules; a trusted payment executor is required before production financial use. |

Rules were not compiled or exercised in an emulator, and indexes were not deployed, as explicitly requested. Review and verify the prototype rules before broadly sharing the app.
