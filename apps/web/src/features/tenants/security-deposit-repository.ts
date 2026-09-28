import { Timestamp, collection, doc, getDoc, getDocs, onSnapshot, orderBy, query, runTransaction, serverTimestamp, where, type Unsubscribe } from 'firebase/firestore';
import { auth, db } from '../../lib/firebase';

export type DepositPaymentMode = 'cash' | 'upi' | 'bank_transfer' | 'cheque' | 'other';
export type DepositTransactionType = 'received' | 'refunded';

export type DepositSubmission = {
  workspaceId: string;
  agreementId: string;
  submissionId: string;
  amountPaise: number;
  transactionDate: Date;
  paymentMode: DepositPaymentMode;
  referenceNumber?: string;
  notes?: string;
};

export type DepositTransaction = {
  id: string;
  submissionId: string;
  workspaceId: string;
  agreementId: string;
  tenantId: string;
  propertyId: string;
  unitId: string;
  transactionType: DepositTransactionType;
  amountPaise: number;
  transactionDate: Timestamp;
  paymentMode: DepositPaymentMode;
  referenceNumber: string;
  notes: string;
  createdBy: string;
  createdAt: Timestamp;
};

export type DepositSummary = {
  workspaceId: string;
  agreementId: string;
  tenantId: string;
  propertyId: string;
  unitId: string;
  agreedAmountPaise: number;
  totalReceivedPaise: number;
  pendingToReceivePaise: number;
  totalRefundedPaise: number;
  heldBalancePaise: number;
  lastTransactionId: string | null;
};

const modes: DepositPaymentMode[] = ['cash', 'upi', 'bank_transfer', 'cheque', 'other'];
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const safePaise = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) >= 0;

/** Generate once per intended movement and retain it across network retries. */
export const newDepositSubmissionId = () => crypto.randomUUID();

function agreementSummary(id: string, agreement: Record<string, unknown>): DepositSummary {
  const agreed = agreement.securityDepositAgreedPaise;
  if (!safePaise(agreed)) throw new Error('Agreement deposit amount is invalid.');
  if (typeof agreement.workspaceId !== 'string' || typeof agreement.tenantId !== 'string' ||
      typeof agreement.propertyId !== 'string' || typeof agreement.unitId !== 'string') {
    throw new Error('Agreement relationships are incomplete.');
  }
  return {
    workspaceId: agreement.workspaceId, agreementId: id, tenantId: agreement.tenantId,
    propertyId: agreement.propertyId, unitId: agreement.unitId,
    agreedAmountPaise: agreed, totalReceivedPaise: 0, pendingToReceivePaise: agreed,
    totalRefundedPaise: 0, heldBalancePaise: 0, lastTransactionId: null,
  };
}

function checkedSummary(base: DepositSummary, saved: Record<string, unknown> | undefined): DepositSummary {
  if (!saved) return base;
  if (saved.workspaceId !== base.workspaceId || saved.agreementId !== base.agreementId ||
      saved.tenantId !== base.tenantId || saved.propertyId !== base.propertyId ||
      saved.unitId !== base.unitId || saved.agreedAmountPaise !== base.agreedAmountPaise ||
      !safePaise(saved.totalReceivedPaise) || !safePaise(saved.totalRefundedPaise) ||
      !safePaise(saved.pendingToReceivePaise) || !safePaise(saved.heldBalancePaise) ||
      saved.totalReceivedPaise > base.agreedAmountPaise || saved.totalRefundedPaise > saved.totalReceivedPaise ||
      saved.pendingToReceivePaise !== base.agreedAmountPaise - saved.totalReceivedPaise ||
      saved.heldBalancePaise !== saved.totalReceivedPaise - saved.totalRefundedPaise ||
      typeof saved.lastTransactionId !== 'string') {
    throw new Error('Deposit summary is inconsistent. No movement was recorded.');
  }
  return saved as DepositSummary;
}

async function recordDeposit(input: DepositSubmission, transactionType: DepositTransactionType): Promise<DepositTransaction> {
  const user = auth.currentUser;
  if (!user) throw new Error('Sign in before recording a deposit movement.');
  if (!input.workspaceId || !input.agreementId) throw new Error('Workspace and agreement are required.');
  if (!uuidPattern.test(input.submissionId)) throw new Error('A stable UUID submission ID is required.');
  if (!safePaise(input.amountPaise) || input.amountPaise === 0) throw new Error('Amount must be positive integer paise.');
  if (!modes.includes(input.paymentMode)) throw new Error('Select a valid payment mode.');
  if (!(input.transactionDate instanceof Date) || !Number.isFinite(input.transactionDate.getTime())) throw new Error('Enter a valid transaction date.');
  const referenceNumber = input.referenceNumber?.trim() ?? '';
  const notes = input.notes?.trim() ?? '';
  if (referenceNumber.length > 200 || notes.length > 2000) throw new Error('Reference or notes are too long.');

  const agreementRef = doc(db, 'rentalAgreements', input.agreementId);
  const summaryRef = doc(db, 'securityDeposits', input.agreementId);
  const movementRef = doc(db, 'securityDepositTransactions', input.submissionId);
  const receiptRef = doc(db, 'securityDepositReceipts', input.submissionId);
  const ledgerRef = doc(db, 'securityDepositLedger', `deposit_${input.submissionId}`);
  await runTransaction(db, async tx => {
    const agreement = await tx.get(agreementRef);
    const summary = await tx.get(summaryRef);
    const previous = await tx.get(movementRef);
    if (!agreement.exists()) throw new Error('Rental agreement could not be found.');
    const base = agreementSummary(agreement.id, agreement.data());
    if (base.workspaceId !== input.workspaceId) throw new Error('Agreement is outside the selected workspace.');
    if (previous.exists()) {
      const saved = previous.data();
      if (saved.workspaceId !== input.workspaceId || saved.agreementId !== input.agreementId ||
          saved.tenantId !== base.tenantId || saved.propertyId !== base.propertyId || saved.unitId !== base.unitId ||
          saved.transactionType !== transactionType || saved.amountPaise !== input.amountPaise ||
          saved.transactionDate.toMillis() !== input.transactionDate.getTime() ||
          saved.paymentMode !== input.paymentMode || saved.referenceNumber !== referenceNumber ||
          saved.notes !== notes || saved.createdBy !== user.uid || saved.submissionId !== input.submissionId) {
        throw new Error('This submission ID already belongs to another deposit movement.');
      }
      return;
    }
    const current = checkedSummary(base, summary.exists() ? summary.data() : undefined);
    if (transactionType === 'received' && input.amountPaise > current.pendingToReceivePaise) {
      throw new Error('Deposit collection exceeds the contractual amount remaining.');
    }
    if (transactionType === 'refunded' && input.amountPaise > current.heldBalancePaise) {
      throw new Error('Refund exceeds the deposit currently held.');
    }
    const tenant = await tx.get(doc(db, 'tenants', base.tenantId));
    const property = await tx.get(doc(db, 'properties', base.propertyId));
    const unit = await tx.get(doc(db, 'units', base.unitId));
    if (!tenant.exists() || !property.exists() || !unit.exists() ||
        tenant.data().workspaceId !== base.workspaceId || property.data().workspaceId !== base.workspaceId ||
        unit.data().workspaceId !== base.workspaceId || unit.data().propertyId !== base.propertyId ||
        typeof tenant.data().fullName !== 'string' || typeof property.data().name !== 'string' ||
        typeof unit.data().name !== 'string') {
      throw new Error('Tenant, property, or unit details are unavailable. Deposit was not recorded.');
    }
    const received = current.totalReceivedPaise + (transactionType === 'received' ? input.amountPaise : 0);
    const refunded = current.totalRefundedPaise + (transactionType === 'refunded' ? input.amountPaise : 0);
    const next = {
      ...base,
      totalReceivedPaise: received,
      pendingToReceivePaise: base.agreedAmountPaise - received,
      totalRefundedPaise: refunded,
      heldBalancePaise: received - refunded,
      lastTransactionId: input.submissionId,
    };
    tx.set(movementRef, {
      workspaceId: base.workspaceId, submissionId: input.submissionId, agreementId: base.agreementId,
      tenantId: base.tenantId, propertyId: base.propertyId, unitId: base.unitId,
      transactionType, amountPaise: input.amountPaise,
      transactionDate: Timestamp.fromDate(input.transactionDate), paymentMode: input.paymentMode,
      referenceNumber, notes, createdBy: user.uid, createdAt: serverTimestamp(),
    });
    const receiptNumber = `${transactionType === 'received' ? 'CRV-D-R-' : 'CRV-D-F-'}${input.submissionId}`;
    tx.set(receiptRef, {
      workspaceId: base.workspaceId, receiptNumber, depositTransactionId: input.submissionId,
      agreementId: base.agreementId, tenantId: base.tenantId, propertyId: base.propertyId, unitId: base.unitId,
      tenantName: tenant.data().fullName, propertyName: property.data().name, unitName: unit.data().name,
      transactionType, amountPaise: input.amountPaise, transactionDate: Timestamp.fromDate(input.transactionDate),
      paymentMode: input.paymentMode, referenceNumber, agreedAmountPaise: base.agreedAmountPaise,
      totalReceivedPaise: next.totalReceivedPaise, heldBalancePaise: next.heldBalancePaise,
      createdBy: user.uid, createdAt: serverTimestamp(),
    });
    tx.set(ledgerRef, {
      workspaceId: base.workspaceId, tenantId: base.tenantId, agreementId: base.agreementId,
      propertyId: base.propertyId, unitId: base.unitId, depositTransactionId: input.submissionId,
      depositReceiptId: input.submissionId, entryType: transactionType === 'received' ? 'deposit_received' : 'deposit_refunded',
      amountPaise: input.amountPaise, transactionDate: Timestamp.fromDate(input.transactionDate),
      paymentMode: input.paymentMode, referenceNumber,
      description: transactionType === 'received' ? 'Security deposit received' : 'Security deposit refunded',
      createdBy: user.uid, createdAt: serverTimestamp(),
    });
    if (summary.exists()) {
      tx.update(summaryRef, {
        totalReceivedPaise: next.totalReceivedPaise, pendingToReceivePaise: next.pendingToReceivePaise,
        totalRefundedPaise: next.totalRefundedPaise, heldBalancePaise: next.heldBalancePaise,
        lastTransactionId: next.lastTransactionId, updatedAt: serverTimestamp(),
      });
    } else {
      tx.set(summaryRef, { ...next, createdAt: serverTimestamp(), updatedAt: serverTimestamp() });
    }
  });
  const saved = await getDoc(movementRef);
  if (!saved.exists()) throw new Error('Deposit movement committed but could not be reloaded. Retry with the same submission ID.');
  return { id: saved.id, ...saved.data() } as DepositTransaction;
}

export const recordDepositReceived = (input: DepositSubmission) => recordDeposit(input, 'received');
export const recordDepositRefund = (input: DepositSubmission) => recordDeposit(input, 'refunded');

export async function getDepositTransaction(workspaceId: string, transactionId: string): Promise<DepositTransaction | null> {
  if (!auth.currentUser) throw new Error('Sign in to view deposits.');
  const item = await getDoc(doc(db, 'securityDepositTransactions', transactionId));
  return item.exists() && item.data().workspaceId === workspaceId ? { id: item.id, ...item.data() } as DepositTransaction : null;
}

export async function getDepositSummary(workspaceId: string, agreementId: string): Promise<DepositSummary> {
  if (!auth.currentUser) throw new Error('Sign in to view deposits.');
  const agreement = await getDoc(doc(db, 'rentalAgreements', agreementId));
  if (!agreement.exists()) throw new Error('Rental agreement could not be found.');
  const base = agreementSummary(agreement.id, agreement.data());
  if (base.workspaceId !== workspaceId) throw new Error('Agreement is outside the selected workspace.');
  const summary = await getDoc(doc(db, 'securityDeposits', agreementId));
  return checkedSummary(base, summary.exists() ? summary.data() : undefined);
}

export async function listDepositTransactions(workspaceId: string, agreementId: string): Promise<DepositTransaction[]> {
  if (!auth.currentUser) throw new Error('Sign in to view deposits.');
  const snapshot = await getDocs(query(collection(db, 'securityDepositTransactions'),
    where('workspaceId', '==', workspaceId), where('agreementId', '==', agreementId), orderBy('transactionDate', 'asc')));
  return snapshot.docs.map(item => ({ id: item.id, ...item.data() } as DepositTransaction))
    .sort((a, b) => a.transactionDate.toMillis() - b.transactionDate.toMillis() || a.id.localeCompare(b.id));
}

/** Read-only Firestore listeners; all financial writes remain in recordDeposit. */
export function listenDepositSummary(workspaceId: string, agreementId: string, next: (value: DepositSummary) => void, fail: (error: Error) => void): Unsubscribe {
  let revision = 0;
  const stop = onSnapshot(doc(db, 'securityDeposits', agreementId), () => {
    const current = ++revision;
    getDepositSummary(workspaceId, agreementId).then(value => { if (current === revision) next(value); }).catch(error => { if (current === revision) fail(error as Error); });
  }, fail);
  return () => { revision++; stop(); };
}

export function listenDepositTransactions(workspaceId: string, agreementId: string, next: (value: DepositTransaction[]) => void, fail: (error: Error) => void): Unsubscribe {
  return onSnapshot(query(collection(db, 'securityDepositTransactions'),
    where('workspaceId', '==', workspaceId), where('agreementId', '==', agreementId), orderBy('transactionDate', 'asc')),
  snapshot => next(snapshot.docs.map(item => ({ id: item.id, ...item.data() } as DepositTransaction))
    .sort((a, b) => a.transactionDate.toMillis() - b.transactionDate.toMillis() || a.id.localeCompare(b.id))), fail);
}
