import { createUserWithEmailAndPassword, sendPasswordResetEmail, signInWithEmailAndPassword, signOut, updateProfile } from 'firebase/auth';
import { auth } from './firebase';

export async function signUpOwner(fullName: string, email: string, password: string) {
  const credential = await createUserWithEmailAndPassword(auth, email.trim(), password);
  await updateProfile(credential.user, { displayName: fullName.trim() });
  return credential.user;
}

export const signIn = (email: string, password: string) => signInWithEmailAndPassword(auth, email.trim(), password);
export const signOutCurrentUser = () => signOut(auth);

// Deliberately show the same confirmation for unknown/known addresses.
export async function requestPasswordReset(email: string) {
  try { await sendPasswordResetEmail(auth, email.trim()); } catch { /* prevent account enumeration in the UI */ }
}

export function friendlyAuthError(error: unknown) {
  const code = (error as { code?: string }).code;
  if (code === 'auth/email-already-in-use') return 'An account already exists with this email. Sign in instead.';
  if (code === 'auth/invalid-credential' || code === 'auth/wrong-password') return 'The email or password is incorrect.';
  if (code === 'auth/too-many-requests') return 'Too many attempts. Please wait a moment and try again.';
  if (code === 'auth/network-request-failed') return 'Check your connection and try again.';
  return 'We could not complete that request. Please try again.';
}
