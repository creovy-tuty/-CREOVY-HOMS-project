# Architecture

CREOVY House Owner is one multi-tenant product, not two client silos.

```text
                     Firebase Authentication
                               |
Flutter Android --- Firebase SDKs --- Cloud Firestore --- React web portal
                               |                 |
                       Firebase Cloud Messaging  Future Cloud Functions
```

Both applications use the same Firebase project and the same authenticated UID. The selected workspace is application state, not an authorization credential. Each Firestore request is authorized by looking up the current UID's active membership for the record's `workspaceId`.

## Authentication lifecycle

1. The client signs in through Firebase Authentication.
2. It upserts its private `users/{uid}` profile (never a workspace authorization source).
3. It reads only active `workspaceMembers` rows for that UID and lets the user select an authorized workspace.
4. A first-time owner creates `workspaces/{workspaceId}` and `workspaceMembers/{workspaceId}_{uid}` atomically.
5. Every subsequent workspace query is filtered by the active `workspaceId`; the rules independently verify membership.

## Boundary and identity model

- `users/{uid}` is the private CREOVY profile for one Firebase Authentication user.
- `workspaces/{workspaceId}` is a customer account / operating workspace.
- `workspaceMembers/{workspaceId}_{uid}` joins an authenticated user to a workspace and holds their role. Its stable, deterministic ID makes it safe and inexpensive for Security Rules to look up.
- Every workspace-owned document is a top-level collection document with `workspaceId`, enabling uniform queries by client and workspace isolation by rules.

The initial workspace setup commits the user profile, workspace, and owner membership in one Firestore batch. It uses the stable initial workspace ID `owner_{uid}`, so a retry cannot create another owner workspace. The rules use `existsAfter` / `getAfter` to permit that bootstrap operation without creating an unauthenticated access gap.

## Client responsibilities

`apps/mobile` owns the Flutter Android experience; `apps/web` owns the React web experience. Neither contains a separate API/database layer. Both call Firebase directly under the same rules.

`packages/contracts` is a technology-neutral product contract: IDs, statuses, money conventions, role names, collection names, and cross-client record shapes. Keep additions compatible with both Dart and TypeScript. Platform-specific Firebase adapters belong in each app.

## Authorization

| Role | Initial capability |
| --- | --- |
| owner | Full workspace administration and data management |
| manager | Property, tenancy, and operational data management |
| accountant | Financial tracking and read access; no property/tenant administration |
| viewer | Read-only workspace access |

Rules protect workspace reads as well as writes. Client navigation and UI permissions are only presentation conveniences; the Firestore rules remain the enforcement point.

## Time, money, and audit rules

- Persist money as integer INR paise (`amountPaise`), never floating point. Display `₹` in the clients.
- Persist dates as Firestore `Timestamp`; format dates in UI as `DD/MM/YYYY` and interpret business dates in `Asia/Kolkata`.
- Use Firestore `serverTimestamp()` for `createdAt` and `updatedAt`. Keep `createdBy` / `updatedBy` UIDs where relevant.
- A rent payment is a new `rentPayments` record for every transaction. The collection is append-only. Do not edit old partial payments to represent a later payment.
- A security deposit is classified independently (`securityDeposits`) and must not be included in rental-income sums.
- EB bills, water tax, and property tax are manually tracked in V1 only.

## Future Cloud Functions boundary

Functions will be the trusted place for derived workflows: generating monthly dues, recomputing due balances/statuses, creating receipts/ledger entries, notification dispatch, exports, and subscription webhooks. They use Admin SDK credentials and must still write `workspaceId` on every workspace record.

Until then, clients may create V1 records only through strict rules. Put complex cross-document invariants in batched writes and do not add a second database or server API.

## FCM foundation

When notifications are introduced, each signed-in client registers its FCM token under `users/{uid}/devices/{deviceId}`. Tokens are private to that user; trusted functions will resolve the intended workspace members, send FCM messages, and create corresponding `notifications` records. FCM tokens are not a source of workspace authorization.
