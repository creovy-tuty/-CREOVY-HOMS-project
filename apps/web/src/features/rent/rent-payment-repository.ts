import { Timestamp, collection, doc, getDoc, getDocs, orderBy, query, runTransaction, serverTimestamp, where } from 'firebase/firestore';
import { auth, db } from '../../lib/firebase';

export type PaymentMode = 'cash' | 'upi' | 'bank_transfer' | 'cheque' | 'other';
export type RentPayment = {
  id: string;
  submissionId: string;
  workspaceId: string;
  rentDueId: string;
  agreementId: string;
  tenantId: string;
  propertyId: string;
  unitId: string;
  periodKey: string;
  amountPaise: number;
  paymentDate: Timestamp;
  paymentMode: PaymentMode;
  referenceNumber: string;
  notes: string;
  createdBy: string;
  createdAt: Timestamp;
};

export type PaymentSubmission = {
  workspaceId: string;
  rentDueId: string;
  submissionId: string;
  amountPaise: number;
  paymentDate: Date;
  paymentMode: PaymentMode;
  referenceNumber?: string;
  notes?: string;
};

const modes: PaymentMode[] = ['cash', 'upi', 'bank_transfer', 'cheque', 'other'];
const submissionPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

/** Generate once when a future payment form opens; retain this value across retries. */
export const newPaymentSubmissionId = () => crypto.randomUUID();

export async function recordPayment(input: PaymentSubmission): Promise<RentPayment> {
  const user = auth.currentUser;
  if (!user) throw new Error('Sign in before recording a payment.');
  if (!submissionPattern.test(input.submissionId)) throw new Error('A valid stable payment submission ID is required.');
  if (!Number.isSafeInteger(input.amountPaise) || input.amountPaise <= 0) throw new Error('Payment must be a positive amount in paise.');
  if (!modes.includes(input.paymentMode)) throw new Error('Select a valid payment mode.');
  if ((input.referenceNumber?.trim().length ?? 0) > 200 || (input.notes?.trim().length ?? 0) > 2000) throw new Error('Payment reference or notes are too long.');
  if (!(input.paymentDate instanceof Date) || !Number.isFinite(input.paymentDate.getTime())) throw new Error('Enter a valid payment date.');
  if (!input.workspaceId || !input.rentDueId) throw new Error('A workspace and rent due are required.');

  const dueRef = doc(db, 'rentDues', input.rentDueId);
  const paymentRef = doc(db, 'rentPayments', input.submissionId);
  const receiptRef = doc(db, 'receipts', input.submissionId);
  const ledgerRef = doc(db, 'tenantLedger', `rent_payment_${input.submissionId}`);
  await runTransaction(db, async transaction => {
    const due = await transaction.get(dueRef);
    const previous = await transaction.get(paymentRef);
    if (previous.exists()) {
      const saved = previous.data() as Omit<RentPayment, 'id'>;
      if (saved.workspaceId !== input.workspaceId || saved.rentDueId !== input.rentDueId ||
          saved.amountPaise !== input.amountPaise || saved.createdBy !== user.uid ||
          saved.paymentMode !== input.paymentMode ||
          saved.paymentDate.toMillis() !== input.paymentDate.getTime() ||
          saved.referenceNumber !== (input.referenceNumber?.trim() ?? '') ||
          saved.notes !== (input.notes?.trim() ?? '')) {
        throw new Error('This submission ID already belongs to another payment.');
      }
      return;
    }
    if (!due.exists()) throw new Error('Rent due could not be found.');
    const current = due.data();
    if (current.workspaceId !== input.workspaceId) throw new Error('Rent due is outside the selected workspace.');
    const rentAmount = current.rentAmountPaise;
    const paid = current.totalPaidPaise;
    const balance = current.balancePaise;
    if (![rentAmount, paid, balance].every(Number.isSafeInteger) ||
        rentAmount < 0 || paid < 0 || balance < 0 || paid + balance !== rentAmount) {
      throw new Error('Rent due totals are inconsistent. Payment was not recorded.');
    }
    if ((paid === 0 && balance > 0 && current.status !== 'pending' && current.status !== 'overdue') ||
        (paid > 0 && balance > 0 && current.status !== 'partial') ||
        (balance === 0 && current.status !== 'paid')) {
      throw new Error('Rent due status is inconsistent. Payment was not recorded.');
    }
    if (balance === 0) throw new Error('This rent due is already fully paid.');
    if (input.amountPaise > balance) throw new Error('Payment exceeds the outstanding balance.');

    const tenant = await transaction.get(doc(db, 'tenants', current.tenantId));
    const property = await transaction.get(doc(db, 'properties', current.propertyId));
    const unit = await transaction.get(doc(db, 'units', current.unitId));
    if (!tenant.exists() || !property.exists() || !unit.exists() ||
        tenant.data().workspaceId !== input.workspaceId || property.data().workspaceId !== input.workspaceId ||
        unit.data().workspaceId !== input.workspaceId) {
      throw new Error('The tenant, property, or unit snapshot is unavailable. Payment was not recorded.');
    }

    const nextPaid = paid + input.amountPaise;
    const nextBalance = balance - input.amountPaise;
    const payment = {
      submissionId: input.submissionId,
      workspaceId: input.workspaceId,
      rentDueId: input.rentDueId,
      agreementId: current.agreementId,
      tenantId: current.tenantId,
      propertyId: current.propertyId,
      unitId: current.unitId,
      periodKey: current.periodKey,
      amountPaise: input.amountPaise,
      paymentDate: Timestamp.fromDate(input.paymentDate),
      paymentMode: input.paymentMode,
      referenceNumber: input.referenceNumber?.trim() ?? '',
      notes: input.notes?.trim() ?? '',
      createdBy: user.uid,
      createdAt: serverTimestamp(),
    };
    transaction.set(paymentRef, payment);
    transaction.set(receiptRef, {
      workspaceId: payment.workspaceId,
      receiptNumber: `CRV-R-${input.submissionId}`,
      paymentId: input.submissionId,
      rentDueId: payment.rentDueId,
      agreementId: payment.agreementId,
      tenantId: payment.tenantId,
      tenantName: tenant.data().fullName,
      propertyId: payment.propertyId,
      propertyName: property.data().name,
      unitId: payment.unitId,
      unitName: unit.data().name,
      periodKey: payment.periodKey,
      amountPaise: payment.amountPaise,
      paymentDate: payment.paymentDate,
      paymentMode: payment.paymentMode,
      referenceNumber: payment.referenceNumber,
      createdBy: user.uid,
      createdAt: serverTimestamp(),
    });
    transaction.set(ledgerRef, {
      workspaceId: payment.workspaceId,
      tenantId: payment.tenantId,
      agreementId: payment.agreementId,
      propertyId: payment.propertyId,
      unitId: payment.unitId,
      rentDueId: payment.rentDueId,
      paymentId: input.submissionId,
      receiptId: receiptRef.id,
      periodKey: payment.periodKey,
      entryType: 'rent_payment',
      amountPaise: payment.amountPaise,
      transactionDate: payment.paymentDate,
      paymentMode: payment.paymentMode,
      referenceNumber: payment.referenceNumber,
      description: `Rent payment for ${payment.periodKey}`,
      createdBy: user.uid,
      createdAt: serverTimestamp(),
    });
    transaction.update(dueRef, {
      totalPaidPaise: nextPaid,
      balancePaise: nextBalance,
      status: nextBalance === 0 ? 'paid' : 'partial',
      updatedAt: serverTimestamp(),
    });
    return;
  });
  const saved = await getDoc(paymentRef);
  if (!saved.exists()) throw new Error('Payment committed but could not be reloaded. Retry with the same submission ID.');
  return { id: saved.id, ...saved.data() } as RentPayment;
}

/** Oldest first, with a stable tie breaker for payments at the same instant. */
export async function listPaymentsForDue(workspaceId: string, rentDueId: string): Promise<RentPayment[]> {
  if (!auth.currentUser) throw new Error('Sign in to view payments.');
  const snapshot = await getDocs(query(
    collection(db, 'rentPayments'),
    where('workspaceId', '==', workspaceId),
    where('rentDueId', '==', rentDueId),
    orderBy('paymentDate', 'asc'),
  ));
  return snapshot.docs.map(item => ({ id: item.id, ...item.data() } as RentPayment))
    .sort((a, b) => a.paymentDate.toMillis() - b.paymentDate.toMillis() || a.id.localeCompare(b.id));
}
