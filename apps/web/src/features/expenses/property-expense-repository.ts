import { Timestamp, collection, doc, getDocFromServer, getDocs, orderBy, query, runTransaction, serverTimestamp, where } from 'firebase/firestore';
import type { PropertyExpense as ExpenseContract, PropertyExpenseCategory, PropertyExpensePaymentMode } from '@creovy/contracts';
import { auth, db } from '../../lib/firebase';

export type PropertyExpense = Omit<ExpenseContract, 'createdAt' | 'updatedAt' | 'expenseDate'> & {
  id: string; createdAt: Timestamp; updatedAt: Timestamp; expenseDate: Timestamp;
};
export type ExpenseSubmission = {
  workspaceId: string; submissionId: string; propertyId: string; unitId?: string | null;
  category: PropertyExpenseCategory; title: string; vendorName?: string; amountPaise: number;
  expenseDate: Date; paymentMode: PropertyExpensePaymentMode; referenceNumber?: string; notes?: string;
};
export type SafeExpenseMetadata = Partial<Pick<ExpenseSubmission, 'title' | 'vendorName' | 'notes'>>;
export type ExpenseFilters = {
  from?: Date; through?: Date; propertyId?: string; unitId?: string;
  category?: PropertyExpenseCategory; paymentMode?: PropertyExpensePaymentMode;
};

const categories: PropertyExpenseCategory[] = ['maintenance', 'repair', 'plumbing', 'electrical', 'cleaning', 'painting', 'security', 'labour', 'common_area', 'other'];
const modes: PropertyExpensePaymentMode[] = ['cash', 'upi', 'bank_transfer', 'cheque', 'other'];
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const signedIn = () => { const user = auth.currentUser; if (!user) throw new Error('Sign in to manage expenses.'); return user; };
const textField = (value: string | undefined, limit: number) => {
  const clean = (value ?? '').trim();
  if (clean.length > limit) throw new Error(`Text exceeds ${limit} characters.`);
  return clean;
};
const expenseOf = (snapshot: { id: string; data: () => unknown }) => ({ id: snapshot.id, ...(snapshot.data() as object) } as PropertyExpense);
const indiaMidnight = (value: Date) => {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(value);
  const part = (type: string) => Number(parts.find(item => item.type === type)?.value);
  return Timestamp.fromMillis(Date.UTC(part('year'), part('month') - 1, part('day')) - 19800000);
};

/** Generate once per actual outflow. Keep this UUID and the financial payload unchanged on retry. */
export const newExpenseSubmissionId = () => crypto.randomUUID();

export async function createExpense(input: ExpenseSubmission): Promise<PropertyExpense> {
  const user = signedIn();
  if (!input.workspaceId || !input.propertyId || !uuid.test(input.submissionId) ||
      !categories.includes(input.category) || !modes.includes(input.paymentMode) ||
      !Number.isSafeInteger(input.amountPaise) || input.amountPaise <= 0 ||
      !(input.expenseDate instanceof Date) || !Number.isFinite(input.expenseDate.getTime())) throw new Error('Invalid expense submission.');
  const title = textField(input.title, 200);
  if (!title) throw new Error('Expense title is required.');
  const vendorName = textField(input.vendorName, 200);
  const referenceNumber = textField(input.referenceNumber, 200);
  const notes = textField(input.notes, 2000);
  const unitId = input.unitId || null;
  const expenseDate = indiaMidnight(input.expenseDate);
  const ref = doc(db, 'propertyExpenses', input.submissionId);
  const workspaceRef = doc(db, 'workspaces', input.workspaceId);
  const membershipRef = doc(db, 'workspaceMembers', `${input.workspaceId}_${user.uid}`);
  const propertyRef = doc(db, 'properties', input.propertyId);
  const unitRef = unitId ? doc(db, 'units', unitId) : null;
  await runTransaction(db, async tx => {
    const workspace = await tx.get(workspaceRef);
    const membership = await tx.get(membershipRef);
    const prior = await tx.get(ref);
    if (!workspace.exists() || workspace.data().status !== 'active' || !membership.exists() ||
        membership.data().workspaceId !== input.workspaceId || membership.data().userId !== user.uid ||
        membership.data().status !== 'active' || !['owner', 'manager', 'accountant'].includes(membership.data().role)) {
      throw new Error('Active financial access to this workspace is required.');
    }
    if (prior.exists()) {
      const saved = prior.data();
      if (saved.workspaceId !== input.workspaceId || saved.submissionId !== input.submissionId ||
          saved.propertyId !== input.propertyId || saved.unitId !== unitId || saved.category !== input.category ||
          saved.amountPaise !== input.amountPaise || !(saved.expenseDate instanceof Timestamp) ||
          saved.expenseDate.toMillis() !== expenseDate.toMillis() || saved.paymentMode !== input.paymentMode ||
          saved.referenceNumber !== referenceNumber || saved.createdBy !== user.uid) {
        throw new Error('Submission ID already belongs to a different expense.');
      }
      return;
    }
    const property = await tx.get(propertyRef);
    const unit = unitRef ? await tx.get(unitRef) : null;
    if (!property.exists() || property.data().workspaceId !== input.workspaceId ||
        (unit && (!unit.exists() || unit.data().workspaceId !== input.workspaceId || unit.data().propertyId !== input.propertyId))) {
      throw new Error('Property or unit does not belong to this workspace.');
    }
    tx.set(ref, { workspaceId: input.workspaceId, submissionId: input.submissionId, propertyId: input.propertyId,
      unitId, category: input.category, title, vendorName, amountPaise: input.amountPaise, expenseDate,
      paymentMode: input.paymentMode, referenceNumber, notes, createdBy: user.uid,
      createdAt: serverTimestamp(), updatedAt: serverTimestamp() });
  });
  const saved = await getDocFromServer(ref);
  if (!saved.exists()) throw new Error('Expense could not be reloaded.');
  return expenseOf(saved);
}

export async function getExpense(workspaceId: string, expenseId: string): Promise<PropertyExpense | null> {
  signedIn();
  const saved = await getDocFromServer(doc(db, 'propertyExpenses', expenseId));
  return saved.exists() && saved.data().workspaceId === workspaceId ? expenseOf(saved) : null;
}

/** One indexed dimension plus date bounds; remaining filters apply after the workspace-scoped query. */
export async function listExpenses(workspaceId: string, filters: ExpenseFilters = {}): Promise<PropertyExpense[]> {
  signedIn();
  if (!workspaceId || filters.from && !Number.isFinite(filters.from.getTime()) ||
      filters.through && !Number.isFinite(filters.through.getTime())) throw new Error('Invalid expense query.');
  const dimensions = filters.unitId ? ['unitId', filters.unitId] : filters.propertyId ? ['propertyId', filters.propertyId] :
    filters.category ? ['category', filters.category] : filters.paymentMode ? ['paymentMode', filters.paymentMode] : null;
  const conditions = [where('workspaceId', '==', workspaceId)];
  if (dimensions) conditions.push(where(dimensions[0], '==', dimensions[1]));
  if (filters.from) conditions.push(where('expenseDate', '>=', indiaMidnight(filters.from)));
  if (filters.through) conditions.push(where('expenseDate', '<=', indiaMidnight(filters.through)));
  const result = await getDocs(query(collection(db, 'propertyExpenses'), ...conditions, orderBy('expenseDate', 'desc')));
  return result.docs.map(expenseOf).filter(item =>
    (!filters.propertyId || item.propertyId === filters.propertyId) && (!filters.unitId || item.unitId === filters.unitId) &&
    (!filters.category || item.category === filters.category) && (!filters.paymentMode || item.paymentMode === filters.paymentMode));
}
export const listExpensesForProperty = (workspaceId: string, propertyId: string, filters: ExpenseFilters = {}) =>
  listExpenses(workspaceId, { ...filters, propertyId });
export const listExpensesForUnit = (workspaceId: string, propertyId: string, unitId: string, filters: ExpenseFilters = {}) =>
  listExpenses(workspaceId, { ...filters, propertyId, unitId });

export async function updateSafeExpenseMetadata(workspaceId: string, expenseId: string, changes: SafeExpenseMetadata): Promise<PropertyExpense> {
  signedIn();
  if (Object.keys(changes).some(key => !['title', 'vendorName', 'notes'].includes(key))) throw new Error('Financial fields cannot be edited.');
  const ref = doc(db, 'propertyExpenses', expenseId);
  await runTransaction(db, async tx => {
    const saved = await tx.get(ref);
    if (!saved.exists() || saved.data().workspaceId !== workspaceId) throw new Error('Expense not found in workspace.');
    const title = changes.title === undefined ? saved.data().title : textField(changes.title, 200);
    if (!title) throw new Error('Expense title is required.');
    tx.update(ref, { title,
      vendorName: changes.vendorName === undefined ? saved.data().vendorName : textField(changes.vendorName, 200),
      notes: changes.notes === undefined ? saved.data().notes : textField(changes.notes, 2000),
      updatedAt: serverTimestamp() });
  });
  const saved = await getDocFromServer(ref);
  if (!saved.exists()) throw new Error('Expense could not be reloaded.');
  return expenseOf(saved);
}
