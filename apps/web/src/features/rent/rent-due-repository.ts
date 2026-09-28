import { Timestamp, collection, doc, getDocFromServer, onSnapshot, query, runTransaction, serverTimestamp, where, type Unsubscribe } from 'firebase/firestore';
import { db } from '../../lib/firebase';
import type { Agreement } from '../tenants/tenant-repository';

export type RentDue = { id: string; workspaceId: string; agreementId: string; tenantId: string; propertyId: string; unitId: string; rentYear: number; rentMonth: number; periodKey: string; dueDate: Timestamp; rentAmountPaise: number; totalPaidPaise: number; balancePaise: number; status: 'pending' | 'partial' | 'paid' | 'overdue'; adjustmentPaise?: number; notes?: string };
const todayIndia = () => { const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(); const at = (type: string) => Number(parts.find(item => item.type === type)?.value); return { year: at('year'), month: at('month'), day: at('day') }; };
export const periodKey = (year: number, month: number) => `${year}-${String(month).padStart(2, '0')}`;
export const dueId = (agreementId: string, key: string) => `${agreementId}_${key}`;
export const dueDateFor = (year: number, month: number, day: number) => {
  const validDay = Math.min(Math.max(day, 1), new Date(Date.UTC(year, month, 0)).getUTCDate());
  return Timestamp.fromDate(new Date(Date.UTC(year, month - 1, validDay - 1, 18, 30)));
};
const monthOf = (date: string) => ({ year: Number(date.slice(0, 4)), month: Number(date.slice(5, 7)) });
const before = (a: { year: number; month: number }, b: { year: number; month: number }) => a.year < b.year || (a.year === b.year && a.month < b.month);
export async function ensureRentDues(workspaceId: string, agreements: Agreement[]) { const now = todayIndia(); for (const agreement of agreements) { if (agreement.workspaceId !== workspaceId || agreement.status === 'draft' || agreement.status === 'cancelled') continue; const start = monthOf(agreement.startDate); const cap = agreement.endDate ? monthOf(agreement.endDate) : { year: now.year, month: now.month }; const end = before(cap, { year: now.year, month: now.month }) ? cap : { year: now.year, month: now.month }; for (let cursor = { ...start }; !before(end, cursor); cursor = cursor.month === 12 ? { year: cursor.year + 1, month: 1 } : { year: cursor.year, month: cursor.month + 1 }) { const key = periodKey(cursor.year, cursor.month); const dueDate = dueDateFor(cursor.year, cursor.month, agreement.rentDueDay); const reference = doc(db, 'rentDues', dueId(agreement.id, key)); await runTransaction(db, async tx => { if ((await tx.get(reference)).exists()) return; tx.set(reference, { workspaceId, agreementId: agreement.id, tenantId: agreement.tenantId, propertyId: agreement.propertyId, unitId: agreement.unitId, rentYear: cursor.year, rentMonth: cursor.month, periodKey: key, dueDate, rentAmountPaise: agreement.monthlyRentPaise, totalPaidPaise: 0, balancePaise: agreement.monthlyRentPaise, status: cursor.year < now.year || (cursor.year === now.year && (cursor.month < now.month || (cursor.month === now.month && Math.min(agreement.rentDueDay, new Date(Date.UTC(cursor.year, cursor.month, 0)).getUTCDate()) < now.day))) ? 'overdue' : 'pending', createdAt: serverTimestamp(), updatedAt: serverTimestamp() }); }); } } }
export function listenRentDues(workspaceId: string, next: (items: RentDue[]) => void, fail: (error: Error) => void): Unsubscribe { return onSnapshot(query(collection(db, 'rentDues'), where('workspaceId', '==', workspaceId)), snapshot => next(snapshot.docs.map(item => ({ id: item.id, ...item.data() } as RentDue))), fail); }
export async function getRentDue(workspaceId: string, rentDueId: string): Promise<RentDue | null> { const snapshot = await getDocFromServer(doc(db, 'rentDues', rentDueId)); return snapshot.exists() && snapshot.data().workspaceId === workspaceId ? { id: snapshot.id, ...snapshot.data() } as RentDue : null; }

export const currentPeriodKey = () => { const today = todayIndia(); return periodKey(today.year, today.month); };
export const isOverdue = (due: RentDue) => {
  const today = todayIndia();
  const date = due.dueDate.toDate();
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(date);
  const at = (type: string) => Number(parts.find(item => item.type === type)?.value);
  const dueDay = { year: at('year'), month: at('month'), day: at('day') };
  return due.balancePaise > 0 && (dueDay.year < today.year ||
    (dueDay.year === today.year && (dueDay.month < today.month ||
      (dueDay.month === today.month && dueDay.day < today.day))));
};
export async function refreshOverdueDues(dues: RentDue[]) {
  for (const due of dues) {
    if (due.status !== 'pending' || !isOverdue(due)) continue;
    const reference = doc(db, 'rentDues', due.id);
    await runTransaction(db, async tx => {
      const current = await tx.get(reference);
      if (!current.exists() || current.data().status !== 'pending' || current.data().balancePaise <= 0) return;
      const date = current.data().dueDate as Timestamp;
      if (!isOverdue({ ...due, dueDate: date, balancePaise: current.data().balancePaise })) return;
      tx.update(reference, { status: 'overdue', updatedAt: serverTimestamp() });
    });
  }
}
