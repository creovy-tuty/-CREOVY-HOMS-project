/** Platform-neutral contract. Firestore adapters map Timestamp values at the edge. */
export const COLLECTIONS = [
  'users', 'workspaces', 'workspaceMembers', 'properties', 'units', 'tenants',
  'rentalAgreements', 'rentDues', 'rentPayments', 'receipts', 'tenantLedger',
  'securityDeposits', 'ebBills', 'waterTaxes', 'propertyTaxes', 'expenses',
  'documents', 'notifications',
] as const;

export type CollectionName = (typeof COLLECTIONS)[number];
export type WorkspaceRole = 'owner' | 'manager' | 'accountant' | 'viewer';
export type MembershipStatus = 'active' | 'invited' | 'suspended';
export type RentDueStatus = 'pending' | 'partial' | 'paid' | 'overdue';
export type TimestampValue = unknown;

export interface WorkspaceOwned {
  workspaceId: string;
  createdAt: TimestampValue;
  updatedAt: TimestampValue;
}

export interface WorkspaceMember {
  workspaceId: string;
  userId: string;
  role: WorkspaceRole;
  status: MembershipStatus;
  createdAt: TimestampValue;
  updatedAt: TimestampValue;
}

export interface RentDue extends WorkspaceOwned {
  agreementId: string;
  tenantId: string;
  propertyId: string;
  unitId: string;
  rentYear: number;
  rentMonth: number;
  periodKey: string;
  dueDate: TimestampValue;
  rentAmountPaise: number;
  totalPaidPaise: number;
  balancePaise: number;
  status: RentDueStatus;
}

export interface RentPayment {
  workspaceId: string;
  submissionId: string;
  rentDueId: string;
  agreementId: string;
  tenantId: string;
  propertyId: string;
  unitId: string;
  periodKey: string;
  amountPaise: number;
  paymentDate: TimestampValue;
  paymentMode: 'cash' | 'upi' | 'bank_transfer' | 'cheque' | 'other';
  referenceNumber: string;
  notes: string;
  createdBy: string;
  createdAt: TimestampValue;
}

export interface RentReceipt {
  workspaceId: string;
  receiptNumber: string;
  paymentId: string;
  rentDueId: string;
  agreementId: string;
  tenantId: string;
  tenantName: string;
  propertyId: string;
  propertyName: string;
  unitId: string;
  unitName: string;
  periodKey: string;
  amountPaise: number;
  paymentDate: TimestampValue;
  paymentMode: RentPayment['paymentMode'];
  referenceNumber: string;
  createdBy: string;
  createdAt: TimestampValue;
}

export interface RentLedgerEntry {
  workspaceId: string;
  tenantId: string;
  agreementId: string;
  propertyId: string;
  unitId: string;
  rentDueId: string;
  paymentId: string;
  receiptId: string;
  periodKey: string;
  entryType: 'rent_payment';
  amountPaise: number;
  transactionDate: TimestampValue;
  paymentMode: RentPayment['paymentMode'];
  referenceNumber: string;
  description: string;
  createdBy: string;
  createdAt: TimestampValue;
}

export const businessDefaults = {
  currency: 'INR',
  timezone: 'Asia/Kolkata',
  dateFormat: 'DD/MM/YYYY',
} as const;
