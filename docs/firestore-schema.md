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
| `rentalAgreements` | `workspaceId`, `propertyId`, `unitId`, `tenantId`, `monthlyRentPaise`, `securityDepositAgreedPaise` (contractual only), `startDate`, `endDate`, `status` |
| `rentDues` | deterministic ID `{agreementId}_{periodKey}`; `workspaceId`, `agreementId`, `tenantId`, `propertyId`, `unitId`, `rentYear`, `rentMonth`, `periodKey`, `dueDate`, `rentAmountPaise`, `totalPaidPaise`, `balancePaise`, `status` |
| `rentPayments` | deterministic document ID = UUID `submissionId`; `workspaceId`, `rentDueId`, `agreementId`, `tenantId`, `propertyId`, `unitId`, `periodKey`, `amountPaise`, `paymentDate: Timestamp`, `paymentMode`, `referenceNumber`, `notes`, `createdBy`, `createdAt`; immutable transaction |
| `receipts` | deterministic document ID `{paymentId}`; `workspaceId`, `receiptNumber`, `paymentId`, `rentDueId`, `agreementId`, `tenantId`, `tenantName`, `propertyId`, `propertyName`, `unitId`, `unitName`, `periodKey`, `amountPaise`, `paymentDate: Timestamp`, `paymentMode`, `referenceNumber`, `createdBy`, `createdAt`; immutable rent-payment and display-name snapshot |
| `tenantLedger` | deterministic rent-payment document ID `rent_payment_{paymentId}`; `workspaceId`, `tenantId`, `agreementId`, `propertyId`, `unitId`, `rentDueId`, `paymentId`, `receiptId`, `periodKey`, `entryType: rent_payment`, `amountPaise`, `transactionDate: Timestamp`, `paymentMode`, `referenceNumber`, `description`, `createdBy`, `createdAt`; immutable journal line |
| `securityDeposits` | document ID = `agreementId`; `workspaceId`, `agreementId`, `tenantId`, `propertyId`, `unitId`, `agreedAmountPaise`, `totalReceivedPaise`, `pendingToReceivePaise`, `totalRefundedPaise`, `heldBalancePaise`, `lastTransactionId`, `createdAt`, `updatedAt` |
| `securityDepositTransactions` | document ID = UUID `submissionId`; `workspaceId`, `agreementId`, `tenantId`, `propertyId`, `unitId`, `transactionType: received/refunded`, `amountPaise`, `transactionDate: Timestamp`, `paymentMode`, `referenceNumber`, `notes`, `submissionId`, `createdBy`, `createdAt`; immutable |
| `securityDepositReceipts` | document ID = deposit transaction UUID; `workspaceId`, `receiptNumber`, `depositTransactionId`, agreement/tenant/property/unit IDs and immutable display-name snapshots, type, amount, date, mode, reference, post-movement agreed/received/held snapshots, actor and audit timestamp |
| `securityDepositLedger` | document ID = `deposit_{depositTransactionId}`; workspace/agreement/tenant/property/unit, deposit transaction/receipt IDs, positive amount, `deposit_received` or `deposit_refunded` direction, transaction date, mode, reference, description, actor and audit timestamp; immutable |
| `propertyBills` | auto ID; `workspaceId`, required `propertyId`, nullable `unitId`, `billType`, `providerName`, `consumerNumber`, `periodKey`, `billDate`, `dueDate`, `amountPaise`, `totalPaidPaise`, `balancePaise`, `status`, `notes`, nullable `lastPaymentId`, `createdBy`, `createdAt`, `updatedAt`; manual V1 tracking |
| `propertyBillPayments` | document ID = stable UUID `submissionId`; `workspaceId`, `billId`, property/unit/type snapshot, `amountPaise`, `paymentDate`, `paymentMode`, `referenceNumber`, `notes`, `createdBy`, `createdAt`; immutable individual payment |
| `ebBills` | `workspaceId`, `propertyId`, `unitId?`, `amountPaise`, `billDate`, `dueDate`, `status`; manual V1 tracking |
| `waterTaxes` | `workspaceId`, `propertyId`, `amountPaise`, `assessmentPeriod`, `dueDate`, `status`; manual V1 tracking |
| `propertyTaxes` | `workspaceId`, `propertyId`, `amountPaise`, `assessmentPeriod`, `dueDate`, `status`; manual V1 tracking |
| `propertyExpenses` | UUID document ID = `submissionId`; `workspaceId`, required `propertyId`, nullable `unitId`, `category`, `title`, `vendorName`, `amountPaise`, `expenseDate`, `paymentMode`, `referenceNumber`, `notes`, `createdBy`, `createdAt`, `updatedAt`; one actual owner outflow per record |
| `expenses` | Legacy placeholder only; reads remain workspace-scoped, client writes are disabled. No migration or deletion is performed. |
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

## Step 7A security deposit movements

`rentalAgreements.securityDepositAgreedPaise` is the contractual ceiling, not evidence of cash received. `securityDepositTransactions` is the immutable movement journal. `securityDeposits/{agreementId}` is the authoritative current balance materialized from successful movements: `pendingToReceivePaise = agreedAmountPaise - totalReceivedPaise` and `heldBalancePaise = totalReceivedPaise - totalRefundedPaise`. The client reads the agreement and summary inside a Firestore transaction, then atomically creates exactly one UUID-keyed movement and creates/updates that one agreement-keyed summary. Concurrent writers contend on the same summary document; a retry with the same UUID and identical details returns its existing movement without changing totals. A different payload under that UUID is rejected. Once a summary exists, the agreement's deposit amount and tenant/property/unit relationships cannot be edited by ordinary clients.

The first movement must be a collection. Later collections cannot exceed the contractual remaining amount; refunds cannot exceed the held balance. There is no automatic refund when an agreement ends, and ended agreements retain all movement history and may receive manual refunds. Transaction relationships come from the agreement, not a UI-provided tenant/property/unit ID. Money is positive integer paise; `transactionDate` is a Firestore timestamp for later `Asia/Kolkata` / `DD/MM/YYYY` display, and audit timestamps use the server clock. Deposits do not write `rentDues`, `rentPayments`, rent `receipts`, or `tenantLedger`. Dedicated deposit receipts and ledger integration remain future work.

Rules require an active owner, manager, or accountant; validate the agreement relationship and amount/mode/actor; disallow movement edits and deletes; and require each summary transition to be paired with one new immutable movement. This client-only design cannot verify that physical money changed hands, defend against Admin SDK or console writes that bypass Security Rules, or prove that an already-existing legacy summary reflects every historical movement. Such records require trusted reconciliation/migration. A trusted server-side executor remains advisable before production financial use. These rules and indexes are prepared locally, not deployed or validated in Step 7A.

## Step 7C deposit receipt and ledger bundle

A new deposit movement now creates four records in one Firestore transaction: `securityDepositTransactions/{submissionId}`, `securityDeposits/{agreementId}`, `securityDepositReceipts/{submissionId}`, and `securityDepositLedger/deposit_{submissionId}`. The same UUID is reused on retry. Receipt number `CRV-D-R-{full UUID}` denotes money received; `CRV-D-F-{full UUID}` denotes a refund. The full UUID makes collisions dependent on the submission ID rather than a client-side sequence. Receipt names are immutable snapshots from the tenant/property/unit source documents at the movement time. Receipt post-movement agreed, total-received, and held fields snapshot the same new summary state; they must not be presented as today's balance after later movements.

Deposit ledger amount is always positive. `deposit_received` and `deposit_refunded` express direction; no rent receipt or tenant rent ledger document is created, and rent KPIs must not include deposits. The ledger is an immutable journal, while `securityDeposits/{agreementId}` remains the current-balance source of truth. New movement rules require both new artifacts in the same commit and validate links, names, amounts, timestamps, and types. Neither receipt nor ledger can be edited or deleted by a client.

Pre-Step 7C development movements may lack both artifacts. A retry with their UUID returns the existing movement and must not synthesize a receipt or ledger entry. A future *trusted, controlled* backfill should enumerate those movement IDs, compare each deterministic receipt/ledger path, inspect workspace and relationship snapshots, report conflicts, and write only missing records with an audit trail. It must not infer historical names or post-movement balances from current state; those require historical evidence or explicit unavailable markers under a separately reviewed migration schema. No automatic backfill runs here.

Client-only limitations remain: rules cannot verify that cash actually changed hands, prove global historical completeness for pre-existing records, or protect against privileged Admin SDK/console writes that bypass rules. A trusted server-side financial executor and reconciliation are recommended before production financial use. Rules and indexes are prepared locally only; Step 7C does not deploy or validate them.

## Step 8A manual bills and taxes

`propertyBills` is the shared Android/Web collection for electricity, water tax, property tax, and other manual bills. The older `ebBills`, `waterTaxes`, and `propertyTaxes` plan is not used by this engine; no migration or deletion is performed. Every bill has one workspace and property; `unitId: null` means a property-level bill, otherwise the unit must belong to that property and workspace. The provider/authority and consumer/assessment references are strings. `periodKey` may be empty when inapplicable. Bill and payment dates are Firestore timestamps, amounts are positive integer INR paise, and audit timestamps use the server clock. Future document references require a separately reviewed schema and Storage design; there is no attachment or upload field in Step 8A.

`dueDate` is the instant at 00:00 Asia/Kolkata on the selected calendar day. A positive balance becomes late at the *following* Asia/Kolkata midnight. `pending` moves to `overdue` only while nothing has been paid. With a partial payment, status remains `partial` even if late; derive late/outstanding context separately from due date and balance. Zero balance is `paid`. `refreshOverdueState` is an explicit client call, not a scheduler. Both clients calculate the same IST boundary and rules compare `request.time` to `dueDate + one day`.

Each intended payment gets one stable UUID, used as both `submissionId` and the `propertyBillPayments` document ID. Android and Web read the bill and that UUID in one Firestore transaction, return an existing payment only when the retry payload and authenticated UID match, reject an amount exceeding the latest balance, then create one immutable payment and update the bill totals, status, `lastPaymentId`, and audit time atomically. Concurrent writers contend on the bill document and retry against the latest balance. No excess is carried forward; previous partial payments remain individual records. Bills and bill payments do not change rent dues, receipts, ledgers, deposits, or rent KPIs.

Before payment, metadata edits can correct provider/authority, consumer/assessment reference, period, notes, bill date, due date, and original amount. Workspace, property, unit, bill type, creator, and creation timestamp never change. After a payment, only notes may be edited (apart from an automatic `pending` to `overdue` refresh), preserving the paid bill's identity and due-date history. Bills with payment history and all payment records are non-deletable by client rules. An eventual archive feature must retain history and be separately reviewed.

Rules require active workspace membership and owner/manager/accountant writes. They validate property and optional unit relationships, amount/type/mode/actor, strict document keys, and legal arithmetic. A bill total update must name a newly created payment in `lastPaymentId`; the payment create rule checks the same bill's before/after delta. This prevents a bill-only total increase and prevents multiple payment IDs from claiming one update under normal client rule enforcement. Security Rules still cannot verify actual money transfer, guarantee all *legacy* data was produced under these rules, prove the client's `dueDate` is precisely IST midnight rather than another timestamp, or constrain privileged Admin SDK/console writes that bypass rules. A trusted executor plus deployment-time rule review is recommended before production financial use. Step 8A does not run tests, rules validation, index deployment, or Firebase deployment.

## Step 9A property-owner expenses

`propertyExpenses/{submissionId}` is one actual owner cash outflow, not a due, balance, or payment schedule. The UUID is generated once per intended expense and retained across retries. The same UUID and financial identity return the existing record; conflicting financial identity is rejected. Safe later edits to `title`, `vendorName`, or `notes` do not invalidate a retry. Create is a single-document transaction after reading the active workspace, active financial-role membership, property, and optional unit. `unitId: null` denotes a whole-property expense. Every record uses positive integer INR paise, a Firestore `expenseDate` timestamp normalized by clients to the selected Asia/Kolkata calendar day's midnight, and server audit timestamps. The fields and stable category/payment-mode values are shared by Web and Flutter. Any future category must be added intentionally to both clients, contract, and rules; old category values remain historical data.

Workspace, property, unit, category, amount, expense date, payment mode, payment reference, creator, submission ID, and creation time are immutable. Only title, vendor name, notes, and server update time can change. Client hard delete is denied. A financial correction requires a future audited reversal/void design, not an in-place rewrite. Supporting invoices/images require a future document relationship and Storage policy; there is no upload or attachment field in Step 9A.

Queries are workspace-scoped and chronologically indexed, with dedicated property, unit, category, and payment-mode chronology indexes plus expense-date range bounds. Multiple simultaneous dimensions can be filtered from the workspace-scoped result after one indexed dimension; future large reports may need additional compound indexes or trusted aggregation. Reports may later compute rent collected minus property expenses as net property cash flow. Security deposits are not income; bill payments remain a separate category unless future reporting deliberately combines them. Expense creation never writes rent, deposit, bill, receipt, or ledger collections and does not alter existing rent KPIs.

These are local prototype rules/index definitions, not deployed or validated in Step 9A. Rules can enforce membership, shape, relationships, identity immutability, and non-deletion for ordinary clients, but cannot prove that money was actually spent, that the client picked the true expense day/category, that historical data predating deployment is complete, or constrain privileged Admin SDK/console writes. Client date normalization cannot be proven to represent IST midnight by rules alone. Production use needs rules/index review, deployment, and preferably a trusted financial executor or reconciliation process.
