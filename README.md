# CREOVY House Owner

Premium multi-tenant property management SaaS. One CREOVY account uses the Android app and web portal against the same Firebase Authentication tenant and Cloud Firestore project.

## Repository layout

```text
apps/mobile/          Flutter Android client
apps/web/             React + TypeScript + Tailwind web portal
packages/contracts/   Shared, platform-neutral domain contract
firebase/             Firestore rules and indexes
docs/                 Architecture and schema decisions
```

## Non-negotiable data boundary

Every tenant-owned record has a `workspaceId`. Firestore Security Rules validate that workspace against the authenticated user's `workspaceMembers/{workspaceId}_{uid}` record. A supplied `workspaceId` alone never grants access.

## Configure a Firebase project

This repository deliberately contains no Firebase credentials. Create or select one Firebase project, then configure both clients to that *same* project:

1. Enable Firebase Authentication (email/password is the initial provider).
2. Create a Cloud Firestore **Standard / Native mode** database in a region chosen for the business.
3. Add the Android and web apps to that project.
4. Copy `apps/web/.env.example` to `apps/web/.env.local` and add the web app configuration.
5. From `apps/mobile`, run `flutterfire configure` and choose the same project. It generates `lib/firebase_options.dart`, which is intentionally gitignored.
6. Deploy the rules and indexes with `npx -y firebase-tools@latest deploy --only firestore --project <your-project-id>`.

See [docs/architecture.md](docs/architecture.md) and [docs/firestore-schema.md](docs/firestore-schema.md) before creating product records.
