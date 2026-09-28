import { collection, doc, getDoc, getDocs, limit, query, serverTimestamp, setDoc, where, writeBatch } from 'firebase/firestore';
import { db } from './firebase';

export type WorkspaceAccess = { id: string; name: string; role: string; ownerId: string };

/** Uses a stable initial workspace ID, making retrying onboarding idempotent. */
export async function bootstrapOwnerWorkspace(input: { uid: string; name: string; fullName: string; mobile: string; email: string }) {
  const workspace = doc(db, 'workspaces', `owner_${input.uid}`);
  const member = doc(db, 'workspaceMembers', `${workspace.id}_${input.uid}`);
  const profile = doc(db, 'users', input.uid);
  const batch = writeBatch(db);
  const audit = { createdAt: serverTimestamp(), updatedAt: serverTimestamp() };
  batch.set(profile, { uid: input.uid, displayName: input.fullName, email: input.email, mobile: input.mobile, status: 'active', activeWorkspaceId: workspace.id, ...audit }, { merge: true });
  batch.set(workspace, { name: input.name, ownerId: input.uid, status: 'active', currency: 'INR', timezone: 'Asia/Kolkata', ...audit }, { merge: true });
  batch.set(member, { workspaceId: workspace.id, userId: input.uid, role: 'owner', status: 'active', ...audit }, { merge: true });
  await batch.commit();
  return workspace.id;
}

/** Membership is the authority; profile.activeWorkspaceId is only a preference. */
export async function resolveAuthorizedWorkspace(uid: string, preferredWorkspaceId?: string): Promise<WorkspaceAccess | null> {
  const memberships = await getDocs(query(collection(db, 'workspaceMembers'), where('userId', '==', uid), where('status', '==', 'active'), limit(20)));
  const candidates = memberships.docs.map((item) => item.data());
  const selected = candidates.find((item) => item.workspaceId === preferredWorkspaceId) ?? candidates[0];
  if (!selected) return null;
  const workspace = await getDoc(doc(db, 'workspaces', selected.workspaceId));
  const data = workspace.data();
  if (!workspace.exists() || !data || data.status !== 'active') return null;
  await setDoc(doc(db, 'users', uid), { activeWorkspaceId: selected.workspaceId, updatedAt: serverTimestamp() }, { merge: true });
  return { id: selected.workspaceId, name: data.name, role: selected.role, ownerId: data.ownerId };
}
