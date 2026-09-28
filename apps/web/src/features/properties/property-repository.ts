import { addDoc, collection, doc, onSnapshot, orderBy, query, runTransaction, serverTimestamp, updateDoc, where, type Unsubscribe } from 'firebase/firestore';
import { db } from '../../lib/firebase';

export type PropertyType = 'independent_house' | 'apartment_building' | 'commercial_building' | 'mixed_use' | 'other';
export type UnitType = 'house' | 'flat' | 'portion' | 'room' | 'shop' | 'office' | 'other';
export type UnitStatus = 'vacant' | 'occupied' | 'maintenance' | 'inactive';
export type Property = { id: string; workspaceId: string; name: string; type: PropertyType; code: string; addressLine1: string; addressLine2?: string; locality: string; city: string; district?: string; state: string; pinCode: string; country: 'India'; floors?: number; notes?: string; ownerName: string; propertyTaxAssessmentNumber?: string; waterConnectionNumber?: string; status: 'active' | 'inactive'; };
export type Unit = { id: string; workspaceId: string; propertyId: string; name: string; type: UnitType; floor?: string; bhk?: string; monthlyRentPaise: number; expectedSecurityDepositPaise: number; ebServiceNumber?: string; notes?: string; status: UnitStatus; };
export type PropertyDraft = Omit<Property, 'id' | 'workspaceId' | 'status'> & { initialUnits: Omit<Unit, 'id' | 'workspaceId' | 'propertyId' | 'status'>[] };

const map = <T>(snapshot: { id: string; data: () => unknown }) => ({ id: snapshot.id, ...(snapshot.data() as Omit<T, 'id'>) }) as T;
export function listenProperties(workspaceId: string, next: (items: Property[]) => void, fail: (error: Error) => void): Unsubscribe { return onSnapshot(query(collection(db, 'properties'), where('workspaceId', '==', workspaceId), orderBy('name')), snapshot => next(snapshot.docs.map(item => map<Property>(item))), fail); }
export function listenUnits(workspaceId: string, propertyId: string, next: (items: Unit[]) => void, fail: (error: Error) => void): Unsubscribe { return onSnapshot(query(collection(db, 'units'), where('workspaceId', '==', workspaceId), where('propertyId', '==', propertyId), orderBy('name')), snapshot => next(snapshot.docs.map(item => map<Unit>(item))), fail); }
export function listenAllUnits(workspaceId: string, next: (items: Unit[]) => void, fail: (error: Error) => void): Unsubscribe { return onSnapshot(query(collection(db, 'units'), where('workspaceId', '==', workspaceId)), snapshot => next(snapshot.docs.map(item => map<Unit>(item))), fail); }
const generatedCode = () => `PROP-${Date.now().toString().slice(-6)}`;
export async function createProperty(workspaceId: string, draft: PropertyDraft) {
  const property = doc(collection(db, 'properties'));
  const code = draft.code.trim().toUpperCase() || generatedCode();
  await runTransaction(db, async transaction => {
    const existing = await transaction.get(query(collection(db, 'properties'), where('workspaceId', '==', workspaceId), where('code', '==', code)));
    if (!existing.empty) throw new Error('This property code is already in use.');
    const audit = { createdAt: serverTimestamp(), updatedAt: serverTimestamp() };
    transaction.set(property, { ...draft, initialUnits: undefined, workspaceId, code, status: 'active', ...audit });
    draft.initialUnits.forEach(unit => transaction.set(doc(collection(db, 'units')), { ...unit, workspaceId, propertyId: property.id, status: 'vacant', ...audit }));
  });
  return property.id;
}
export async function updateProperty(propertyId: string, update: Partial<Property>) { await updateDoc(doc(db, 'properties', propertyId), { ...update, updatedAt: serverTimestamp() }); }
export async function archiveProperty(propertyId: string) { await updateProperty(propertyId, { status: 'inactive' }); }
export async function createUnit(workspaceId: string, propertyId: string, unit: Omit<Unit, 'id' | 'workspaceId' | 'propertyId' | 'status'>) { await addDoc(collection(db, 'units'), { ...unit, workspaceId, propertyId, status: 'vacant', createdAt: serverTimestamp(), updatedAt: serverTimestamp() }); }
export async function updateUnit(unitId: string, update: Partial<Unit>) { await updateDoc(doc(db, 'units', unitId), { ...update, updatedAt: serverTimestamp() }); }
export async function deactivateUnit(unitId: string) { await updateUnit(unitId, { status: 'inactive' }); }
