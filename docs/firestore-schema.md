# Firestore schema plan

All IDs are Firestore auto IDs unless a deterministic ID is explicitly stated. All workspace-owned documents include `workspaceId: string`, `createdAt: Timestamp`, and `updatedAt: Timestamp` unless immutable. Monetary fields are non-negative integer paise (`amountPaise`) in INR.

| Collection | Core fields / relationship |
| --- | --- |
| `users` | `uid`, `displayName`, `email`, `activeWorkspaceId`, `createdAt` |
| `workspaces` | `name`, `ownerId`, `timezone: "Asia/Kolkata"`, `currency: "INR"` |
| `workspaceMembers` | deterministic ID `{workspaceId}_{uid}`; `workspaceId`, `userId`, `role`, `status` |
| `properties` | `workspaceId`, `name`, `address`, `status` |
| `units` | `workspaceId`, `propertyId`, `name`, `status`, `monthlyRentPaise` |
| `tenants` | `workspaceId`, `fullName`, `phone`, `email`, `status` |
| `rentalAgreements` | `workspaceId`, `propertyId`, `unitId`, `tenantId`, `monthlyRentPaise`, `startDate`, `endDate`, `status` |
| `rentDues` | deterministic ID `{agreementId}_{periodKey}`; `workspaceId`, `agreementId`, `tenantId`, `propertyId`, `unitId`, `rentYear`, `rentMonth`, `periodKey`, `dueDate`, `rentAmountPaise`, `totalPaidPaise`, `balancePaise`, `status` |
| `rentPayments` | deterministic document ID = UUID `submissionId`; `workspaceId`, `rentDueId`, `agreementId`, `tenantId`, `propertyId`, `unitId`, `periodKey`, `amountPaise`, `paymentDate: Timestamp`, `paymentMode`, `referenceNumber`, `notes`, `createdBy`, `createdAt`; immutable transaction |
| `receipts` | deterministic document ID `{paymentId}`; `workspaceId`, `receiptNumber`, `paymentId`, `rentDueId`, `agreementId`, `tenantId`, `tenantName`, `propertyId`, `propertyName`, `unitId`, `unitName`, `periodKey`, `amountPaise`, `paymentDate: Timestamp`, `paymentMode`, `referenceNumber`, `createdBy`, `createdAt`; immutable rent-payment and display-name snapshot |
| `tenantLedger` | deterministic rent-payment document ID `rent_payment_{paymentId}`; `workspaceId`, `tenantId`, `agreementId`, `propertyId`, `unitId`, `rentDueId`, `paymentId`, `receiptId`, `periodKey`, `entryType: rent_payment`, `amountPaise`, `transactionDate: Timestamp`, `paymentMode`, `referenceNumber`, `description`, `createdBy`, `createdAt`; immutable journal line |
| `securityDeposits` | `workspaceId`, `tenantId`, `agreementId`, `amountPaise`, `status`, `receivedAt`, `refundedAt` |
| `ebBills` | `workspaceId`, `propertyId`, `unitId?`, `amountPaise`, `billDate`, `dueDate`, `status`; manual V1 tracking |
| `waterTaxes` | `workspaceId`, `propertyId`, `amountPaise`, `assessmentPeriod`, `dueDate`, `status`; manual V1 tracking |
| `propertyTaxes` | `workspaceId`, `propertyId`, `amountPaise`, `assessmentPeriod`, `dueDate`, `status`; manual V1 tracking |
| `expenses` | `workspaceId`, `propertyId?`, `unitId?`, `category`, `amountPaise`, `expenseDate`, `status` |
| `documents` | `workspaceId`, `entityType`, `entityId`, `storagePath`, `fileName`, `contentType` |
| `notifications` | `workspaceId`, `userId?`, `type`, `title`, `body`, `readAt?`, `createdAt` |

## Rent due state machine

```text
new due -> pending -> overdue
              |           |
              +-> partial <-+
                    |
                    +-> paid
pending/overdue -> paid (full payment)
```

`totalPaidPaise` is the sum of individual payment records. `balancePaise = rentAmountPaise - totalPaidPaise`. `paid` requires a zero balance. Only an unpaid `pending` due transitions to `overdue`; an unpaid balance with some payment remains `partial`, even after the due date. A later payment is inserted as a new `rentPayments` document and never replaces an earlier one.

## Required write discipline

Create each new rent payment, its updated due summary, its receipt, and its rent ledger entry in one transaction. A future trusted backend should become the canonical executor for the full financial workflow. Do not record a security deposit as a `rentPayment` or rent ledger credit.

## Step 6B-1 payment transaction contract

The caller generates one UUID for one intended rent payment and retains it across retries. Both clients use that UUID as the `rentPayments` document ID. In one Firestore transaction they read the due and UUID document; an existing matching payment is returned unchanged. For a new payment, they require a positive integer paise amount no greater than the current balance, create an append-only payment, and update the due totals/status atomically. Concurrent attempts on the same due retry against the latest balance.

Both clients submit `paymentDate` as a Firestore timestamp representing an instant, normalized to millisecond precision for idempotent retry comparison; display is later formatted in `Asia/Kolkata` as `DD/MM/YYYY`. `createdBy` is taken from the current Firebase Auth UID, never from caller input. A retry must use the same UUID, amount, date, mode, reference number, notes, due, workspace, and authenticated user; a new UUID always represents a separate intended payment.

`totalPaidPaise` is the sum of successful payment amounts and `balancePaise = rentAmountPaise - totalPaidPaise`. A positive paid amount with a positive balance is `partial`; a zero balance is `paid`. A partially paid due can also be late, but the primary status remains `partial`.

The prepared composite indexes cover payment history by workspace and rent due (ascending payment date), by tenant and period (descending payment date), and across a workspace (descending payment date). No indexes are deployed by this step.

Firestore Rules validate payment-to-due relationships and require the due's post-transaction totals to reflect each new payment. A signed-in client may read an absent UUID document to check idempotency, but existing payment contents require membership in its workspace. The rules can check payment creation against `getAfter(rentDues/{id})`, but a due-only client update cannot identify an accompanying newly created payment without an additional payment ID field or a trusted backend. The due update rule restricts fields and arithmetic, yet a malicious authorized client could still forge a due-only total increase. The rules also cannot prove a one-to-one relationship between a due update and multiple same-amount payment creations in a single batch. Treat client-driven financial writes as an interim architecture: move payment recording to a trusted Cloud Function before production financial use, and deny direct client due/payment writes at that point.

## Step 6C-1 receipt and rent ledger bundle

For new payments, the same Firestore transaction now creates `rentPayments/{paymentId}`, updates the due, creates `receipts/{paymentId}`, and creates `tenantLedger/rent_payment_{paymentId}`. The client derives both immutable financial snapshots from the successful payment values; it never accepts their amounts independently. Rules require the two derived documents to be newly present in the payment commit and validate their workspace, relationship, amount, mode, reference, actor, and timestamps against the new payment. A retry with the same payment ID returns the existing payment and does not create or rewrite its receipt or ledger line.

The receipt also snapshots the tenant, property, and unit display names read in that transaction. Rules compare those names and workspace ownership to the corresponding source documents; later name changes do not rewrite the receipt. If a source entity is unavailable, a new payment is rejected rather than producing an incomplete receipt.

The display number is `CRV-R-{paymentId}`, while the receipt document ID remains `{paymentId}`. The full payment UUID is retained—no truncated suffix or local sequence—so the number is deterministic and unique wherever the payment ID is unique, including within each workspace. It is recognizable to a person but longer than a sequential invoice number. Concurrent submissions cannot claim the same payment/receipt/ledger paths independently. Neither a per-device counter nor a client-editable workspace counter is used.

Receipts and ledger entries are append-only and represent individual payments, not running rent totals. `paymentDate` and `transactionDate` are Firestore timestamps representing the same payment instant; `createdAt` is a server timestamp. Display formatting later uses `Asia/Kolkata` and `DD/MM/YYYY`. Receipt/ledger records intentionally contain no security-deposit, expense, fee, reversal, or PDF fields in this step.

Payments created before Step 6C-1 may lack derived records. Normal clients must not synthesize them on retry. A future controlled backfill should enumerate old payments, inspect each deterministic receipt/ledger ID and amount/relationship, report conflicts, then create only missing records with an audited trusted migration. No backfill is run here.

The prior client-only limitation remains: rules cannot prove that every due-total increase corresponds to exactly one payment, nor prevent an authorized malicious client from placing multiple equal-amount payment bundles against one matching due delta in one batch. The new bundle rules protect the payment-to-receipt-to-ledger relationship for each client-created payment, but they do not solve the global due accounting invariant. A trusted payment executor and rule review are required before production financial use. Rules and indexes are prepared locally only; this step does not deploy or validate them.
