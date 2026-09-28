import { Timestamp, collection, doc, getDoc, getDocs, onSnapshot, orderBy, query, where, type Unsubscribe } from 'firebase/firestore';
import { auth, db } from '../../lib/firebase';
import type { DepositPaymentMode, DepositTransactionType } from './security-deposit-repository';

export type DepositReceipt = {
  id: string; workspaceId: string; receiptNumber: string; depositTransactionId: string;
  agreementId: string; tenantId: string; propertyId: string; unitId: string;
  tenantName: string; propertyName: string; unitName: string;
  transactionType: DepositTransactionType; amountPaise: number; transactionDate: Timestamp;
  paymentMode: DepositPaymentMode; referenceNumber: string;
  agreedAmountPaise: number; totalReceivedPaise: number; heldBalancePaise: number;
  createdBy: string; createdAt: Timestamp;
};
export type DepositLedgerEntry = {
  id: string; workspaceId: string; tenantId: string; agreementId: string; propertyId: string; unitId: string;
  depositTransactionId: string; depositReceiptId: string; entryType: 'deposit_received' | 'deposit_refunded';
  amountPaise: number; transactionDate: Timestamp; paymentMode: DepositPaymentMode;
  referenceNumber: string; description: string; createdBy: string; createdAt: Timestamp;
};

function requireSignIn() { if (!auth.currentUser) throw new Error('Sign in to view deposit records.'); }
const receiptOf = (item: { id: string; data: () => unknown }) => ({ id: item.id, ...(item.data() as Record<string, unknown>) } as DepositReceipt);
const ledgerOf = (item: { id: string; data: () => unknown }) => ({ id: item.id, ...(item.data() as Record<string, unknown>) } as DepositLedgerEntry);

/** Null is expected for a pre-Step 7C movement; never synthesize it in a client retry. */
export async function getDepositReceipt(workspaceId: string, transactionId: string): Promise<DepositReceipt | null> {
  requireSignIn();
  const item = await getDoc(doc(db, 'securityDepositReceipts', transactionId));
  return item.exists() && item.data().workspaceId === workspaceId ? receiptOf(item) : null;
}

export async function getDepositLedgerEntry(workspaceId: string, transactionId: string): Promise<DepositLedgerEntry | null> {
  requireSignIn();
  const item = await getDoc(doc(db, 'securityDepositLedger', `deposit_${transactionId}`));
  return item.exists() && item.data().workspaceId === workspaceId ? ledgerOf(item) : null;
}

export async function listDepositLedger(workspaceId: string, agreementId: string): Promise<DepositLedgerEntry[]> {
  requireSignIn();
  const result = await getDocs(query(collection(db, 'securityDepositLedger'), where('workspaceId', '==', workspaceId), where('agreementId', '==', agreementId), orderBy('transactionDate', 'asc')));
  return result.docs.map(ledgerOf).sort((a, b) => a.transactionDate.toMillis() - b.transactionDate.toMillis() || a.id.localeCompare(b.id));
}

export function listenDepositLedger(workspaceId: string, agreementId: string, next: (entries: DepositLedgerEntry[]) => void, fail: (error: Error) => void): Unsubscribe {
  return onSnapshot(query(collection(db, 'securityDepositLedger'), where('workspaceId', '==', workspaceId), where('agreementId', '==', agreementId), orderBy('transactionDate', 'asc')),
    result => next(result.docs.map(ledgerOf).sort((a, b) => a.transactionDate.toMillis() - b.transactionDate.toMillis() || a.id.localeCompare(b.id))), fail);
}
