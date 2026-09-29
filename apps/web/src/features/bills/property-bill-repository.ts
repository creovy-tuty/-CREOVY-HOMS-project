import { Timestamp, collection, doc, getDoc, getDocFromServer, getDocs, onSnapshot, orderBy, query, runTransaction, serverTimestamp, where, type Unsubscribe } from 'firebase/firestore';
import type { PropertyBill as BillContract, PropertyBillPayment as PaymentContract, PropertyBillPaymentMode, PropertyBillType, PropertyBillStatus } from '@creovy/contracts';
import { auth, db } from '../../lib/firebase';

export type PropertyBill = Omit<BillContract, 'createdAt' | 'updatedAt' | 'billDate' | 'dueDate'> & {
  id: string; createdAt: Timestamp; updatedAt: Timestamp; billDate: Timestamp; dueDate: Timestamp;
};
export type PropertyBillPayment = Omit<PaymentContract, 'createdAt' | 'paymentDate'> & {
  id: string; createdAt: Timestamp; paymentDate: Timestamp;
};
export type BillDraft = {
  workspaceId: string; propertyId: string; unitId?: string | null; billType: PropertyBillType;
  providerName: string; consumerNumber?: string; periodKey?: string; billDate: Date; dueDate: Date;
  amountPaise: number; notes?: string;
};
export type SafeBillMetadata = Partial<Pick<BillDraft, 'providerName' | 'consumerNumber' | 'periodKey' | 'billDate' | 'dueDate' | 'notes' | 'amountPaise'>>;
export type BillPaymentSubmission = {
  workspaceId: string; billId: string; submissionId: string; amountPaise: number;
  paymentDate: Date; paymentMode: PropertyBillPaymentMode; referenceNumber?: string; notes?: string;
};

const types: PropertyBillType[] = ['electricity', 'water_tax', 'property_tax', 'other'];
const modes: PropertyBillPaymentMode[] = ['cash', 'upi', 'bank_transfer', 'cheque', 'other'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_PAISE = Number.MAX_SAFE_INTEGER;
const validMoney = (value: number) => Number.isSafeInteger(value) && value > 0 && value <= MAX_PAISE;
const validDate = (value: Date) => value instanceof Date && Number.isFinite(value.getTime());
const partsIndia = (value: Date) => {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(value);
  const part = (type: string) => Number(parts.find(item => item.type === type)?.value);
  return { year: part('year'), month: part('month'), day: part('day') };
};
/** A due date is stored at 00:00 IST; it becomes overdue at the next IST midnight. */
const indiaMidnight = (date: Date) => {
  const { year, month, day } = partsIndia(date);
  return Timestamp.fromMillis(Date.UTC(year, month - 1, day) - 19800000);
};
const overdue = (date: Timestamp, now = Date.now()) => now >= date.toMillis() + 86400000;
export const isPropertyBillLate = (bill: PropertyBill) => bill.balancePaise > 0 && overdue(bill.dueDate);
/** Generate once per intended payment; keep the UUID and payload unchanged on retry. */
export const newBillPaymentSubmissionId = () => crypto.randomUUID();
const signedIn = () => { const user = auth.currentUser; if (!user) throw new Error('Sign in to manage bills.'); return user; };
const billOf = (item: { id: string; data: () => unknown }) => ({ id: item.id, ...(item.data() as object) } as PropertyBill);
const paymentOf = (item: { id: string; data: () => unknown }) => ({ id: item.id, ...(item.data() as object) } as PropertyBillPayment);
const textField = (value: string | undefined, max: number) => {
  const clean = (value ?? '').trim();
  if (clean.length > max) throw new Error(`Text exceeds ${max} characters.`);
  return clean;
};
const statusFor = (paid: number, balance: number, due: Timestamp): PropertyBillStatus =>
  balance === 0 ? 'paid' : paid > 0 ? 'partial' : overdue(due) ? 'overdue' : 'pending';
function assertBillTotals(bill: Record<string, unknown>): void {
  const amount = bill.amountPaise; const paid = bill.totalPaidPaise; const balance = bill.balancePaise;
  if (!validMoney(amount as number) || !Number.isSafeInteger(paid as number) || !Number.isSafeInteger(balance as number) ||
      (paid as number) < 0 || (balance as number) < 0 || (paid as number) + (balance as number) !== amount ||
      !(bill.dueDate instanceof Timestamp) || bill.status !== statusFor(paid as number, balance as number, bill.dueDate) &&
      !(paid === 0 && balance > 0 && (bill.status === 'pending' || bill.status === 'overdue'))) {
    throw new Error('Bill totals or status are inconsistent.');
  }
}

export async function createBill(input: BillDraft): Promise<PropertyBill> {
  const user = signedIn();
  if (!input.workspaceId || !input.propertyId || !types.includes(input.billType) || !validMoney(input.amountPaise) ||
      !validDate(input.billDate) || !validDate(input.dueDate)) throw new Error('Invalid bill details.');
  const providerName = textField(input.providerName, 200);
  if (!providerName) throw new Error('Provider or authority name is required.');
  const consumerNumber = textField(input.consumerNumber, 200);
  const periodKey = textField(input.periodKey, 40);
  const notes = textField(input.notes, 2000);
  const billDate = Timestamp.fromDate(input.billDate);
  const dueDate = indiaMidnight(input.dueDate);
  if (dueDate.toMillis() < indiaMidnight(input.billDate).toMillis()) throw new Error('Due date precedes bill date.');
  const propertyRef = doc(db, 'properties', input.propertyId);
  const unitRef = input.unitId ? doc(db, 'units', input.unitId) : null;
  const billRef = doc(collection(db, 'propertyBills'));
  await runTransaction(db, async tx => {
    const property = await tx.get(propertyRef);
    const unit = unitRef ? await tx.get(unitRef) : null;
    if (!property.exists() || property.data().workspaceId !== input.workspaceId ||
        (unit && (!unit.exists() || unit.data().workspaceId !== input.workspaceId || unit.data().propertyId !== input.propertyId))) {
      throw new Error('Property or unit does not belong to this workspace.');
    }
    tx.set(billRef, {
      workspaceId: input.workspaceId, propertyId: input.propertyId, unitId: input.unitId || null,
      billType: input.billType, providerName, consumerNumber, periodKey, billDate, dueDate,
      amountPaise: input.amountPaise, totalPaidPaise: 0, balancePaise: input.amountPaise,
      status: statusFor(0, input.amountPaise, dueDate), notes, lastPaymentId: null,
      createdBy: user.uid, createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
    });
  });
  const saved = await getDoc(billRef);
  if (!saved.exists()) throw new Error('Bill was created but could not be reloaded.');
  return billOf(saved);
}

export async function updateSafeBillMetadata(workspaceId: string, billId: string, changes: SafeBillMetadata): Promise<PropertyBill> {
  signedIn();
  const allowed = ['providerName', 'consumerNumber', 'periodKey', 'billDate', 'dueDate', 'notes', 'amountPaise'];
  if (Object.keys(changes).some(key => !allowed.includes(key))) throw new Error('Unsupported bill edit.');
  const reference = doc(db, 'propertyBills', billId);
  await runTransaction(db, async tx => {
    const snapshot = await tx.get(reference);
    if (!snapshot.exists() || snapshot.data().workspaceId !== workspaceId) throw new Error('Bill not found in workspace.');
    const current = snapshot.data(); assertBillTotals(current);
    if ((current.totalPaidPaise !== 0 || current.lastPaymentId !== null) && Object.keys(changes).some(key => key !== 'notes')) {
      throw new Error('Only notes can be edited after a payment.');
    }
    const amount = changes.amountPaise ?? current.amountPaise;
    if (!validMoney(amount)) throw new Error('Amount must be positive integer paise.');
    const billDate = changes.billDate === undefined ? current.billDate as Timestamp : Timestamp.fromDate(changes.billDate);
    const dueDate = changes.dueDate === undefined ? current.dueDate as Timestamp : indiaMidnight(changes.dueDate);
    if (changes.billDate && !validDate(changes.billDate) || changes.dueDate && !validDate(changes.dueDate) ||
        dueDate.toMillis() < indiaMidnight(billDate.toDate()).toMillis()) throw new Error('Invalid bill or due date.');
    const providerName = changes.providerName === undefined ? current.providerName : textField(changes.providerName, 200);
    if (!providerName) throw new Error('Provider or authority name is required.');
    tx.update(reference, {
      providerName, consumerNumber: changes.consumerNumber === undefined ? current.consumerNumber : textField(changes.consumerNumber, 200),
      periodKey: changes.periodKey === undefined ? current.periodKey : textField(changes.periodKey, 40),
      notes: changes.notes === undefined ? current.notes : textField(changes.notes, 2000),
      billDate, dueDate, amountPaise: amount, balancePaise: amount - current.totalPaidPaise,
      status: statusFor(current.totalPaidPaise, amount - current.totalPaidPaise, dueDate), updatedAt: serverTimestamp(),
    });
  });
  const saved = await getDoc(reference);
  if (!saved.exists()) throw new Error('Bill was updated but could not be reloaded.');
  return billOf(saved);
}

export async function getBill(workspaceId: string, billId: string): Promise<PropertyBill | null> {
  signedIn();
  const saved = await getDocFromServer(doc(db, 'propertyBills', billId));
  return saved.exists() && saved.data().workspaceId === workspaceId ? billOf(saved) : null;
}

/** Workspace-scoped chronology; optional filters are applied to the result. */
export async function listBills(workspaceId: string, filters: Partial<Pick<PropertyBill, 'propertyId' | 'unitId' | 'billType' | 'status' | 'periodKey'>> = {}): Promise<PropertyBill[]> {
  signedIn();
  const result = await getDocs(query(collection(db, 'propertyBills'), where('workspaceId', '==', workspaceId), orderBy('dueDate', 'asc')));
  return result.docs.map(billOf).filter(bill => Object.entries(filters).every(([key, value]) => bill[key as keyof PropertyBill] === value));
}

export function listenBills(workspaceId: string, next: (bills: PropertyBill[]) => void, fail: (error: Error) => void): Unsubscribe {
  signedIn();
  return onSnapshot(query(collection(db, 'propertyBills'), where('workspaceId', '==', workspaceId), orderBy('dueDate', 'asc')),
    result => next(result.docs.map(billOf)), fail);
}

export async function recordBillPayment(input: BillPaymentSubmission): Promise<PropertyBillPayment> {
  const user = signedIn();
  if (!input.workspaceId || !input.billId || !uuid.test(input.submissionId) || !validMoney(input.amountPaise) ||
      !validDate(input.paymentDate) || !modes.includes(input.paymentMode)) throw new Error('Invalid bill payment submission.');
  const referenceNumber = textField(input.referenceNumber, 200);
  const notes = textField(input.notes, 2000);
  const paymentDate = Timestamp.fromMillis(input.paymentDate.getTime());
  const billRef = doc(db, 'propertyBills', input.billId);
  const paymentRef = doc(db, 'propertyBillPayments', input.submissionId);
  await runTransaction(db, async tx => {
    const bill = await tx.get(billRef);
    const previous = await tx.get(paymentRef);
    if (previous.exists()) {
      const saved = previous.data();
      if (saved.workspaceId !== input.workspaceId || saved.billId !== input.billId || saved.submissionId !== input.submissionId ||
          saved.amountPaise !== input.amountPaise || saved.paymentDate.toMillis() !== paymentDate.toMillis() ||
          saved.paymentMode !== input.paymentMode || saved.referenceNumber !== referenceNumber || saved.notes !== notes ||
          saved.createdBy !== user.uid) throw new Error('Submission ID already belongs to another payment.');
      return;
    }
    if (!bill.exists() || bill.data().workspaceId !== input.workspaceId) throw new Error('Bill not found in workspace.');
    const current = bill.data(); assertBillTotals(current);
    if (input.amountPaise > current.balancePaise) throw new Error('Payment exceeds the outstanding balance.');
    const balance = current.balancePaise - input.amountPaise;
    tx.set(paymentRef, {
      workspaceId: input.workspaceId, submissionId: input.submissionId, billId: input.billId,
      propertyId: current.propertyId, unitId: current.unitId, billType: current.billType,
      amountPaise: input.amountPaise, paymentDate, paymentMode: input.paymentMode,
      referenceNumber, notes, createdBy: user.uid, createdAt: serverTimestamp(),
    });
    tx.update(billRef, {
      totalPaidPaise: current.totalPaidPaise + input.amountPaise, balancePaise: balance,
      status: balance === 0 ? 'paid' : 'partial', lastPaymentId: input.submissionId,
      updatedAt: serverTimestamp(),
    });
  });
  const saved = await getDoc(paymentRef);
  if (!saved.exists()) throw new Error('Payment committed but could not be reloaded. Retry with the same submission ID.');
  return paymentOf(saved);
}

export async function listBillPayments(workspaceId: string, billId: string): Promise<PropertyBillPayment[]> {
  signedIn();
  const result = await getDocs(query(collection(db, 'propertyBillPayments'), where('workspaceId', '==', workspaceId),
    where('billId', '==', billId), orderBy('paymentDate', 'asc')));
  return result.docs.map(paymentOf).sort((a, b) => a.paymentDate.toMillis() - b.paymentDate.toMillis() || a.id.localeCompare(b.id));
}

export function listenBillPayments(workspaceId: string, billId: string, next: (payments: PropertyBillPayment[]) => void, fail: (error: Error) => void): Unsubscribe {
  signedIn();
  return onSnapshot(query(collection(db, 'propertyBillPayments'), where('workspaceId', '==', workspaceId), where('billId', '==', billId), orderBy('paymentDate', 'asc')),
    result => next(result.docs.map(paymentOf)), fail);
}

/** Read a stable UUID before retrying an uncertain network submission. */
export async function getBillPayment(workspaceId: string, submissionId: string): Promise<PropertyBillPayment | null> {
  signedIn();
  const saved = await getDocFromServer(doc(db, 'propertyBillPayments', submissionId));
  return saved.exists() && saved.data().workspaceId === workspaceId ? paymentOf(saved) : null;
}

/** Only unpaid/unpartially-paid bills move pending -> overdue. Late partials remain partial. */
export async function refreshOverdueState(workspaceId: string, billId: string): Promise<PropertyBill | null> {
  signedIn();
  const reference = doc(db, 'propertyBills', billId);
  await runTransaction(db, async tx => {
    const bill = await tx.get(reference);
    if (!bill.exists() || bill.data().workspaceId !== workspaceId) return;
    const current = bill.data(); assertBillTotals(current);
    if (current.status === 'pending' && current.totalPaidPaise === 0 && current.balancePaise > 0 && overdue(current.dueDate)) {
      tx.update(reference, { status: 'overdue', updatedAt: serverTimestamp() });
    }
  });
  return getBill(workspaceId, billId);
}
