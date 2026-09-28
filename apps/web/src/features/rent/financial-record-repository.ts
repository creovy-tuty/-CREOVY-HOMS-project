import { Timestamp, collection, doc, getDoc, getDocs, orderBy, query, where } from 'firebase/firestore';
import { auth, db } from '../../lib/firebase';
import type { PaymentMode } from './rent-payment-repository';

export type RentReceipt = {
  id: string; workspaceId: string; receiptNumber: string; paymentId: string; rentDueId: string;
  agreementId: string; tenantId: string; tenantName: string; propertyId: string; propertyName: string;
  unitId: string; unitName: string; periodKey: string;
  amountPaise: number; paymentDate: Timestamp; paymentMode: PaymentMode; referenceNumber: string;
  createdBy: string; createdAt: Timestamp;
};
export type RentLedgerEntry = {
  id: string; workspaceId: string; tenantId: string; agreementId: string; propertyId: string;
  unitId: string; rentDueId: string; paymentId: string; receiptId: string; periodKey: string;
  entryType: 'rent_payment'; amountPaise: number; transactionDate: Timestamp;
  paymentMode: PaymentMode; referenceNumber: string; description: string;
  createdBy: string; createdAt: Timestamp;
};

function requireSignIn() { if (!auth.currentUser) throw new Error('Sign in to view financial records.'); }
const receipts = collection(db, 'receipts');
const ledger = collection(db, 'tenantLedger');
const receiptOf = (item: { id: string; data: () => unknown }) => ({ id: item.id, ...(item.data() as Record<string, unknown>) } as RentReceipt);
const entryOf = (item: { id: string; data: () => unknown }) => ({ id: item.id, ...(item.data() as Record<string, unknown>) } as RentLedgerEntry);

/** New receipts use their payment UUID as the document ID. Legacy payments may return null. */
export async function getReceiptByPayment(workspaceId: string, paymentId: string): Promise<RentReceipt | null> {
  requireSignIn();
  const item = await getDoc(doc(db, 'receipts', paymentId));
  return item.exists() && item.data().workspaceId === workspaceId ? receiptOf(item) : null;
}

export async function listReceiptsForTenant(workspaceId: string, tenantId: string): Promise<RentReceipt[]> {
  requireSignIn();
  const result = await getDocs(query(receipts, where('workspaceId', '==', workspaceId), where('tenantId', '==', tenantId), orderBy('createdAt', 'desc')));
  return result.docs.map(receiptOf);
}

export async function listWorkspaceReceipts(workspaceId: string): Promise<RentReceipt[]> {
  requireSignIn();
  const result = await getDocs(query(receipts, where('workspaceId', '==', workspaceId), orderBy('createdAt', 'desc')));
  return result.docs.map(receiptOf);
}

export async function findReceiptByNumber(workspaceId: string, receiptNumber: string): Promise<RentReceipt | null> {
  requireSignIn();
  const result = await getDocs(query(receipts, where('workspaceId', '==', workspaceId), where('receiptNumber', '==', receiptNumber)));
  return result.empty ? null : receiptOf(result.docs[0]);
}

export async function listTenantLedger(workspaceId: string, tenantId: string): Promise<RentLedgerEntry[]> {
  requireSignIn();
  const result = await getDocs(query(ledger, where('workspaceId', '==', workspaceId), where('tenantId', '==', tenantId), orderBy('transactionDate', 'asc')));
  return result.docs.map(entryOf).sort((a, b) => a.transactionDate.toMillis() - b.transactionDate.toMillis() || a.id.localeCompare(b.id));
}

export async function listWorkspaceLedger(workspaceId: string): Promise<RentLedgerEntry[]> {
  requireSignIn();
  const result = await getDocs(query(ledger, where('workspaceId', '==', workspaceId), orderBy('transactionDate', 'desc')));
  return result.docs.map(entryOf);
}

export async function listAgreementLedger(workspaceId: string, agreementId: string): Promise<RentLedgerEntry[]> {
  requireSignIn();
  const result = await getDocs(query(ledger, where('workspaceId', '==', workspaceId), where('agreementId', '==', agreementId), orderBy('transactionDate', 'asc')));
  return result.docs.map(entryOf).sort((a, b) => a.transactionDate.toMillis() - b.transactionDate.toMillis() || a.id.localeCompare(b.id));
}
