/** Platform-neutral contract. Firestore adapters map Timestamp values at the edge. */
export const COLLECTIONS = [
  'users', 'workspaces', 'workspaceMembers', 'properties', 'units', 'tenants',
  'rentalAgreements', 'rentDues', 'rentPayments', 'receipts', 'tenantLedger',
  'securityDeposits', 'securityDepositTransactions', 'securityDepositReceipts', 'securityDepositLedger', 'propertyBills', 'propertyBillPayments', 'ebBills', 'waterTaxes', 'propertyTaxes', 'expenses',
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

export type DepositTransactionType = 'received' | 'refunded';
export type DepositPaymentMode = RentPayment['paymentMode'];
export type PropertyBillType = 'electricity' | 'water_tax' | 'property_tax' | 'other';
export type PropertyBillStatus = 'pending' | 'partial' | 'paid' | 'overdue';
export type PropertyBillPaymentMode = RentPayment['paymentMode'];

/** propertyBills/{autoId}; unitId is null for a property-level bill. */
export interface PropertyBill extends WorkspaceOwned {
  propertyId: string;
  unitId: string | null;
  billType: PropertyBillType;
  providerName: string;
  consumerNumber: string;
  periodKey: string;
  billDate: TimestampValue;
  dueDate: TimestampValue;
  amountPaise: number;
  totalPaidPaise: number;
  balancePaise: number;
  status: PropertyBillStatus;
  notes: string;
  lastPaymentId: string | null;
  createdBy: string;
}

/** propertyBillPayments/{submissionId}; immutable individual payment. */
export interface PropertyBillPayment {
  workspaceId: string;
  submissionId: string;
  billId: string;
  propertyId: string;
  unitId: string | null;
  billType: PropertyBillType;
  amountPaise: number;
  paymentDate: TimestampValue;
  paymentMode: PropertyBillPaymentMode;
  referenceNumber: string;
  notes: string;
  createdBy: string;
  createdAt: TimestampValue;
}

/** Immutable movement. Document ID equals submissionId (a stable UUID). */
export interface SecurityDepositTransaction {
  workspaceId: string;
  submissionId: string;
  agreementId: string;
  tenantId: string;
  propertyId: string;
  unitId: string;
  transactionType: DepositTransactionType;
  amountPaise: number;
  transactionDate: TimestampValue;
  paymentMode: DepositPaymentMode;
  referenceNumber: string;
  notes: string;
  createdBy: string;
  createdAt: TimestampValue;
}

/** securityDeposits/{agreementId}: atomic current balance, not a rent ledger. */
export interface SecurityDepositSummary {
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
  lastTransactionId: string;
  createdAt: TimestampValue;
  updatedAt: TimestampValue;
}

/** securityDepositReceipts/{depositTransactionId}: immutable owner-facing snapshot. */
export interface SecurityDepositReceipt {
  workspaceId: string;
  receiptNumber: string;
  depositTransactionId: string;
  agreementId: string;
  tenantId: string;
  propertyId: string;
  unitId: string;
  tenantName: string;
  propertyName: string;
  unitName: string;
  transactionType: DepositTransactionType;
  amountPaise: number;
  transactionDate: TimestampValue;
  paymentMode: DepositPaymentMode;
  referenceNumber: string;
  agreedAmountPaise: number;
  totalReceivedPaise: number;
  heldBalancePaise: number;
  createdBy: string;
  createdAt: TimestampValue;
}

/** securityDepositLedger/deposit_{depositTransactionId}: immutable journal. */
export interface SecurityDepositLedgerEntry {
  workspaceId: string;
  tenantId: string;
  agreementId: string;
  propertyId: string;
  unitId: string;
  depositTransactionId: string;
  depositReceiptId: string;
  entryType: 'deposit_received' | 'deposit_refunded';
  amountPaise: number;
  transactionDate: TimestampValue;
  paymentMode: DepositPaymentMode;
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
