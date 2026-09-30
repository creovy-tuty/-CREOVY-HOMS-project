import { Timestamp, collection, doc, getDocFromServer, getDocs, limit, orderBy, query, where, type QueryConstraint } from 'firebase/firestore';
import type { BillsReport, DepositReport, ExpenseReport, MonthlyCashFlowRow, OccupancyReport, PortfolioSummary,
  PropertyPerformanceRow, RentReport, ReportFilters, ReportHistoryRow, ReportMoneyGroup, ReportRentRow, TenantRentReport } from '@creovy/contracts';
import { auth, db } from '../../lib/firebase';

export type WebReportFilters = Omit<ReportFilters, 'from' | 'through'> & { from?: Date; through?: Date };
type Row = { id: string; data: Record<string, unknown> };
type Dimension = [string, string] | null;
const MAX_ROWS_PER_SOURCE = 3000;
const DAY_MS = 86400000;

function signedIn(): void { if (!auth.currentUser) throw new Error('Sign in to view reports.'); }
function dateParts(value: Date) {
  const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(value);
  const part = (type: string) => Number(parts.find(item => item.type === type)?.value);
  return { year: part('year'), month: part('month'), day: part('day') };
}
function dayStart(value: Date): number { const { year, month, day } = dateParts(value); return Date.UTC(year, month - 1, day) - 19800000; }
function businessDate(value: Date): string { const { year, month, day } = dateParts(value); return `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`; }
function monthKey(value: Date): string { return businessDate(value).slice(0, 7); }
function checkFilters(workspaceId: string, filters: WebReportFilters) {
  signedIn();
  if (!workspaceId || [filters.from, filters.through].some(value => value !== undefined && (!(value instanceof Date) || !Number.isFinite(value.getTime()))) ||
      filters.from && filters.through && dayStart(filters.from) > dayStart(filters.through)) throw new Error('Invalid report workspace or date range.');
  if (filters.rentStatus && !['pending', 'partial', 'paid', 'overdue'].includes(filters.rentStatus) ||
      filters.billType && !['electricity', 'water_tax', 'property_tax', 'other'].includes(filters.billType) ||
      filters.expenseCategory && !['maintenance', 'repair', 'plumbing', 'electrical', 'cleaning', 'painting', 'security', 'labour', 'common_area', 'other'].includes(filters.expenseCategory))
    throw new Error('Invalid report category or status filter.');
}
function string(row: Row, key: string): string { const value = row.data[key]; if (typeof value !== 'string') throw new Error(`Invalid ${key} in ${row.id}.`); return value; }
function money(row: Row, key: string): number { const value = row.data[key]; if (typeof value !== 'number' || !Number.isSafeInteger(value) || value < 0) throw new Error(`Invalid ${key} in ${row.id}.`); return value; }
function stamp(row: Row, key: string): Timestamp { const value = row.data[key]; if (!(value instanceof Timestamp)) throw new Error(`Invalid ${key} in ${row.id}.`); return value; }
function sum(values: number[]): number { return values.reduce((total, value) => { const result = total + value; if (!Number.isSafeInteger(result)) throw new Error('Report total exceeds safe integer paise.'); return result; }, 0); }
function rate(numerator: number, denominator: number): number { return denominator === 0 ? 0 : Math.round(numerator / denominator * 10000) / 100; }
function matchesLocation(row: Row, filters: WebReportFilters): boolean {
  return (!filters.propertyId || row.data.propertyId === filters.propertyId) &&
    (!filters.unitId || row.data.unitId === filters.unitId);
}
function matchesPerson(row: Row, filters: WebReportFilters): boolean {
  return matchesLocation(row, filters) &&
    (!filters.tenantId || row.data.tenantId === filters.tenantId) &&
    (!filters.agreementId || row.data.agreementId === filters.agreementId);
}
function rejectTenantScopedNet(filters: WebReportFilters) {
  if (filters.tenantId || filters.agreementId || filters.rentStatus || filters.expenseCategory)
    throw new Error('Net cash flow supports date/property/unit filters only; use the specialized reports for tenant, status, or category filters.');
}
function dimension(filters: WebReportFilters, keys: (keyof WebReportFilters)[]): Dimension {
  for (const key of keys) if (typeof filters[key] === 'string' && filters[key]) return [key, filters[key] as string];
  return null;
}
async function readRows(name: string, workspaceId: string, filters: WebReportFilters, dateField?: string, indexedDimension: Dimension = null, direction: 'asc' | 'desc' = 'desc'): Promise<Row[]> {
  checkFilters(workspaceId, filters);
  const constraints: QueryConstraint[] = [where('workspaceId', '==', workspaceId)];
  if (indexedDimension) constraints.push(where(indexedDimension[0], '==', indexedDimension[1]));
  if (dateField) {
    if (filters.from) constraints.push(where(dateField, '>=', Timestamp.fromMillis(dayStart(filters.from))));
    if (filters.through) constraints.push(where(dateField, '<', Timestamp.fromMillis(dayStart(filters.through) + DAY_MS)));
    constraints.push(orderBy(dateField, direction));
  }
  const result = await getDocs(query(collection(db, name), ...constraints, limit(MAX_ROWS_PER_SOURCE + 1)));
  if (result.size > MAX_ROWS_PER_SOURCE) throw new Error(`${name} exceeds the client reporting limit; narrow the date or property filter.`);
  return result.docs.map(item => ({ id: item.id, data: item.data() as Record<string, unknown> }));
}
const dues = (ws: string, f: WebReportFilters) => readRows('rentDues', ws, f, 'dueDate', dimension(f, ['tenantId', 'propertyId']));
const rentPayments = (ws: string, f: WebReportFilters) => readRows('rentPayments', ws, f, 'paymentDate', dimension(f, ['tenantId', 'propertyId']));
const expenses = (ws: string, f: WebReportFilters) => {
  const indexed: Dimension = f.unitId ? ['unitId', f.unitId] : f.propertyId ? ['propertyId', f.propertyId] :
    f.expenseCategory ? ['category', f.expenseCategory] : null;
  return readRows('propertyExpenses', ws, f, 'expenseDate', indexed);
};
const bills = (ws: string, f: WebReportFilters) => readRows('propertyBills', ws, f, 'billDate', dimension(f, ['propertyId', 'billType']));
const billPayments = (ws: string, f: WebReportFilters) => readRows('propertyBillPayments', ws, f, 'paymentDate', dimension(f, ['propertyId']));
const depositTransactions = (ws: string, f: WebReportFilters) => {
  const indexed = dimension(f, ['tenantId', 'agreementId', 'propertyId']);
  return readRows('securityDepositTransactions', ws, f, 'transactionDate', indexed, indexed?.[0] === 'tenantId' || indexed?.[0] === 'agreementId' ? 'asc' : 'desc');
};
const agreements = (ws: string) => readRows('rentalAgreements', ws, {});
const depositSummaries = (ws: string) => readRows('securityDeposits', ws, {});
const units = (ws: string) => readRows('units', ws, {});
const properties = (ws: string) => readRows('properties', ws, {});
const tenants = (ws: string) => readRows('tenants', ws, {});

function relevantDues(rows: Row[], filters: WebReportFilters, asOf: number): Row[] {
  return rows.filter(row => matchesPerson(row, filters) && (!filters.rentStatus || derivedRentStatus(row, asOf) === filters.rentStatus));
}
function derivedRentStatus(row: Row, asOf: number): string {
  if (money(row, 'balancePaise') === 0) return 'paid';
  if (money(row, 'totalPaidPaise') > 0) return 'partial';
  return stamp(row, 'dueDate').toMillis() < asOf ? 'overdue' : 'pending';
}
function rentResult(dueRows: Row[], paymentRows: Row[], filters: WebReportFilters): RentReport {
  const asOf = dayStart(new Date());
  const selectedDues = relevantDues(dueRows, filters, asOf);
  const dueIds = new Set(selectedDues.map(row => row.id));
  const selectedPayments = paymentRows.filter(row => matchesPerson(row, filters) && (!filters.rentStatus || dueIds.has(string(row, 'rentDueId'))));
  const expectedRentPaise = sum(selectedDues.map(row => money(row, 'rentAmountPaise')));
  const rentCollectedPaise = sum(selectedPayments.map(row => money(row, 'amountPaise')));
  const collectedAgainstExpectedPaise = sum(selectedPayments.filter(row => dueIds.has(string(row, 'rentDueId'))).map(row => money(row, 'amountPaise')));
  const outstandingPaise = sum(selectedDues.map(row => money(row, 'balancePaise')));
  const overduePaise = sum(selectedDues.filter(row => stamp(row, 'dueDate').toMillis() < asOf).map(row => money(row, 'balancePaise')));
  return { expectedRentPaise, rentCollectedPaise, collectedAgainstExpectedPaise, outstandingPaise, overduePaise,
    collectionRatePercent: rate(collectedAgainstExpectedPaise, expectedRentPaise), dueCount: selectedDues.length,
    paymentCount: selectedPayments.length, asOfBusinessDate: businessDate(new Date()) };
}
function groups(rows: Row[], key: string): ReportMoneyGroup[] {
  const values = new Map<string, { amountPaise: number; count: number }>();
  for (const row of rows) {
    const groupKey = string(row, key);
    const current = values.get(groupKey) ?? { amountPaise: 0, count: 0 };
    values.set(groupKey, { amountPaise: sum([current.amountPaise, money(row, 'amountPaise')]), count: current.count + 1 });
  }
  return [...values].sort(([a], [b]) => a.localeCompare(b)).map(([keyValue, value]) => ({ key: keyValue, ...value }));
}
function expenseResult(rows: Row[], filters: WebReportFilters): ExpenseReport {
  const selected = rows.filter(row => matchesLocation(row, filters) && (!filters.expenseCategory || row.data.category === filters.expenseCategory));
  return { totalExpensesPaise: sum(selected.map(row => money(row, 'amountPaise'))), expenseCount: selected.length,
    byCategory: groups(selected, 'category'), byProperty: groups(selected, 'propertyId'),
    byUnit: groups(selected.filter(row => row.data.unitId != null), 'unitId') };
}
function billsResult(billRows: Row[], paymentRows: Row[], filters: WebReportFilters): BillsReport {
  const selectedBills = billRows.filter(row => matchesLocation(row, filters) && (!filters.billType || row.data.billType === filters.billType));
  const selectedPayments = paymentRows.filter(row => matchesLocation(row, filters) && (!filters.billType || row.data.billType === filters.billType));
  const asOf = dayStart(new Date());
  return { billsRaisedPaise: sum(selectedBills.map(row => money(row, 'amountPaise'))),
    billsPaidPaise: sum(selectedPayments.map(row => money(row, 'amountPaise'))),
    billsOutstandingPaise: sum(selectedBills.map(row => money(row, 'balancePaise'))),
    billsOverduePaise: sum(selectedBills.filter(row => stamp(row, 'dueDate').toMillis() < asOf).map(row => money(row, 'balancePaise'))),
    paymentsByBillType: groups(selectedPayments, 'billType'), billCount: selectedBills.length,
    paymentCount: selectedPayments.length, asOfBusinessDate: businessDate(new Date()) };
}
function depositResult(agreementRows: Row[], summaryRows: Row[], txRows: Row[], filters: WebReportFilters): DepositReport {
  const eligible = agreementRows.filter(row => matchesPerson(row, filters) && !['draft', 'cancelled'].includes(string(row, 'status')));
  const summaries = summaryRows.filter(row => matchesPerson(row, filters));
  const tx = txRows.filter(row => matchesPerson(row, filters));
  return { depositAgreedPaise: sum(eligible.map(row => money(row, 'securityDepositAgreedPaise'))),
    depositReceivedPaise: sum(tx.filter(row => row.data.transactionType === 'received').map(row => money(row, 'amountPaise'))),
    depositRefundedPaise: sum(tx.filter(row => row.data.transactionType === 'refunded').map(row => money(row, 'amountPaise'))),
    depositCurrentlyHeldPaise: sum(summaries.map(row => money(row, 'heldBalancePaise'))), transactionCount: tx.length };
}
function occupancyResult(unitRows: Row[], agreementRows: Row[], filters: WebReportFilters): OccupancyReport {
  const inventory = unitRows.filter(row => (!filters.propertyId || row.data.propertyId === filters.propertyId) && (!filters.unitId || row.id === filters.unitId));
  const related = agreementRows.filter(row => matchesPerson(row, filters));
  const active = related.filter(row => row.data.status === 'active');
  const occupiedIds = new Set(agreementRows.filter(row => row.data.status === 'active').map(row => string(row, 'unitId')));
  const rentable = inventory.filter(row => !['inactive', 'maintenance'].includes(string(row, 'status')));
  const occupiedUnits = rentable.filter(row => occupiedIds.has(row.id)).length;
  return { totalRentableUnits: rentable.length, occupiedUnits, vacantUnits: rentable.length - occupiedUnits,
    maintenanceUnits: inventory.filter(row => row.data.status === 'maintenance').length,
    inactiveUnits: inventory.filter(row => row.data.status === 'inactive').length,
    occupancyRatePercent: rate(occupiedUnits, rentable.length),
    activeTenants: new Set(active.map(row => string(row, 'tenantId'))).size,
    activeAgreements: active.length,
    upcomingAgreements: related.filter(row => row.data.status === 'upcoming').length,
    endedAgreements: related.filter(row => row.data.status === 'ended').length };
}

export async function getRentReport(workspaceId: string, filters: WebReportFilters = {}): Promise<RentReport> {
  checkFilters(workspaceId, filters);
  const [dueRows, payments] = await Promise.all([dues(workspaceId, filters), rentPayments(workspaceId, filters)]);
  return rentResult(dueRows, payments, filters);
}
export async function getRentBreakdown(workspaceId: string, filters: WebReportFilters = {}): Promise<ReportRentRow[]> {
  checkFilters(workspaceId, filters);
  const [dueRows, propertyRows, unitRows, tenantRows] = await Promise.all([
    dues(workspaceId, filters), properties(workspaceId), units(workspaceId), tenants(workspaceId),
  ]);
  const names = (rows: Row[], key: string) => new Map(rows.map(row => [row.id, string(row, key)]));
  const propertyNames = names(propertyRows, 'name'), unitNames = names(unitRows, 'name'), tenantNames = names(tenantRows, 'fullName');
  return relevantDues(dueRows, filters, dayStart(new Date())).map(row => ({
    dueId: row.id, tenantId: string(row, 'tenantId'), tenantName: tenantNames.get(string(row, 'tenantId')) ?? 'Tenant',
    agreementId: string(row, 'agreementId'), propertyId: string(row, 'propertyId'),
    propertyName: propertyNames.get(string(row, 'propertyId')) ?? 'Property', unitId: string(row, 'unitId'),
    unitName: unitNames.get(string(row, 'unitId')) ?? 'Unit', periodKey: string(row, 'periodKey'),
    dueDate: stamp(row, 'dueDate'), expectedPaise: money(row, 'rentAmountPaise'),
    paidPaise: money(row, 'totalPaidPaise'), balancePaise: money(row, 'balancePaise'),
    status: derivedRentStatus(row, dayStart(new Date())) as ReportRentRow['status'],
  }));
}
export async function getExpenseReport(workspaceId: string, filters: WebReportFilters = {}): Promise<ExpenseReport> {
  checkFilters(workspaceId, filters);
  return expenseResult(await expenses(workspaceId, filters), filters);
}
export async function getBillsReport(workspaceId: string, filters: WebReportFilters = {}): Promise<BillsReport> {
  checkFilters(workspaceId, filters);
  const [billRows, payments] = await Promise.all([bills(workspaceId, filters), billPayments(workspaceId, filters)]);
  return billsResult(billRows, payments, filters);
}
export async function getDepositReport(workspaceId: string, filters: WebReportFilters = {}): Promise<DepositReport> {
  checkFilters(workspaceId, filters);
  const [agreementRows, summaries, tx] = await Promise.all([agreements(workspaceId), depositSummaries(workspaceId), depositTransactions(workspaceId, filters)]);
  return depositResult(agreementRows, summaries, tx, filters);
}
export async function getOccupancyReport(workspaceId: string, filters: WebReportFilters = {}): Promise<OccupancyReport> {
  checkFilters(workspaceId, filters);
  const [unitRows, agreementRows] = await Promise.all([units(workspaceId), agreements(workspaceId)]);
  return occupancyResult(unitRows, agreementRows, filters);
}
export async function getPortfolioSummary(workspaceId: string, filters: WebReportFilters = {}): Promise<PortfolioSummary> {
  checkFilters(workspaceId, filters);
  rejectTenantScopedNet(filters);
  const [rent, expense, bill, deposit, occupancy] = await Promise.all([
    getRentReport(workspaceId, filters), getExpenseReport(workspaceId, filters), getBillsReport(workspaceId, filters),
    getDepositReport(workspaceId, filters), getOccupancyReport(workspaceId, filters),
  ]);
  return { rent, expenses: expense, bills: bill, deposits: deposit, occupancy,
    netPropertyCashFlowPaise: sum([rent.rentCollectedPaise, -expense.totalExpensesPaise]) };
}
export async function getPropertyPerformance(workspaceId: string, filters: WebReportFilters = {}): Promise<PropertyPerformanceRow[]> {
  checkFilters(workspaceId, filters);
  rejectTenantScopedNet(filters);
  const [propertyRows, dueRows, payments, expenseRows, unitRows, agreementRows] = await Promise.all([
    properties(workspaceId), dues(workspaceId, filters), rentPayments(workspaceId, filters),
    expenses(workspaceId, filters), units(workspaceId), agreements(workspaceId),
  ]);
  const selectedUnit = filters.unitId ? unitRows.find(row => row.id === filters.unitId) : undefined;
  return propertyRows.filter(row => (!filters.propertyId || row.id === filters.propertyId) &&
    (!filters.unitId || selectedUnit?.data.propertyId === row.id)).map(property => {
    const scoped: WebReportFilters = { ...filters, propertyId: property.id };
    const rent = rentResult(dueRows, payments, scoped);
    const expense = expenseResult(expenseRows, scoped);
    const occupancy = occupancyResult(unitRows, agreementRows, scoped);
    return { propertyId: property.id, propertyName: string(property, 'name'), expectedRentPaise: rent.expectedRentPaise,
      rentCollectedPaise: rent.rentCollectedPaise, outstandingPaise: rent.outstandingPaise,
      propertyExpensesPaise: expense.totalExpensesPaise,
      netCashFlowPaise: sum([rent.rentCollectedPaise, -expense.totalExpensesPaise]),
      totalRentableUnits: occupancy.totalRentableUnits, occupiedUnits: occupancy.occupiedUnits,
      occupancyRatePercent: occupancy.occupancyRatePercent };
  });
}
export async function getTenantRentReport(workspaceId: string, tenantId: string, filters: WebReportFilters = {}): Promise<TenantRentReport> {
  const scoped = { ...filters, tenantId };
  checkFilters(workspaceId, scoped);
  if (!tenantId) throw new Error('Tenant is required.');
  const [tenant, dueRows, payments] = await Promise.all([
    getDocFromServer(doc(db, 'tenants', tenantId)), dues(workspaceId, scoped), rentPayments(workspaceId, scoped),
  ]);
  if (!tenant.exists() || tenant.data().workspaceId !== workspaceId) throw new Error('Tenant not found in workspace.');
  const selectedDues = relevantDues(dueRows, scoped, dayStart(new Date()));
  const dueIds = new Set(selectedDues.map(row => row.id));
  const selectedPayments = payments.filter(row => matchesPerson(row, scoped) && (!scoped.rentStatus || dueIds.has(string(row, 'rentDueId'))));
  const history = (row: Row, amountField: string, dateField: string, includeBalance: boolean): ReportHistoryRow => ({
    id: row.id, agreementId: string(row, 'agreementId'), propertyId: string(row, 'propertyId'), unitId: string(row, 'unitId'),
    periodKey: string(row, 'periodKey'), amountPaise: money(row, amountField),
    ...(includeBalance ? { paidPaise: money(row, 'totalPaidPaise'), balancePaise: money(row, 'balancePaise') } : {}), date: stamp(row, dateField),
  });
  return { tenantId, tenantName: tenant.data().fullName ?? '', rent: rentResult(dueRows, payments, scoped),
    dues: selectedDues.map(row => history(row, 'rentAmountPaise', 'dueDate', true)),
    payments: selectedPayments.map(row => history(row, 'amountPaise', 'paymentDate', false)) };
}
export async function getAgreementRentReport(workspaceId: string, agreementId: string, filters: WebReportFilters = {}): Promise<TenantRentReport> {
  checkFilters(workspaceId, filters);
  if (!agreementId) throw new Error('Agreement is required.');
  const agreement = await getDocFromServer(doc(db, 'rentalAgreements', agreementId));
  if (!agreement.exists() || agreement.data().workspaceId !== workspaceId || typeof agreement.data().tenantId !== 'string')
    throw new Error('Agreement not found in workspace.');
  return getTenantRentReport(workspaceId, agreement.data().tenantId, { ...filters, agreementId });
}
function nextMonth(key: string): string { const year = Number(key.slice(0, 4)), month = Number(key.slice(5, 7)); return month === 12 ? `${year + 1}-01` : `${year}-${String(month + 1).padStart(2, '0')}`; }
export async function getMonthlyCashFlowTrend(workspaceId: string, filters: WebReportFilters = {}): Promise<MonthlyCashFlowRow[]> {
  checkFilters(workspaceId, filters);
  rejectTenantScopedNet(filters);
  const [dueRows, payments, expenseRows] = await Promise.all([dues(workspaceId, filters), rentPayments(workspaceId, filters), expenses(workspaceId, filters)]);
  const selectedDues = relevantDues(dueRows, filters, dayStart(new Date()));
  const dueIds = new Set(selectedDues.map(row => row.id));
  const selectedPayments = payments.filter(row => matchesPerson(row, filters) && (!filters.rentStatus || dueIds.has(string(row, 'rentDueId'))));
  const selectedExpenses = expenseRows.filter(row => matchesLocation(row, filters) && (!filters.expenseCategory || row.data.category === filters.expenseCategory));
  const months = new Map<string, MonthlyCashFlowRow>();
  const bucket = (key: string) => { let row = months.get(key); if (!row) { row = { periodKey: key, expectedRentPaise: 0, rentCollectedPaise: 0, propertyExpensesPaise: 0, netCashFlowPaise: 0 }; months.set(key, row); } return row; };
  for (const row of selectedDues) { const item = bucket(string(row, 'periodKey')); item.expectedRentPaise = sum([item.expectedRentPaise, money(row, 'rentAmountPaise')]); }
  for (const row of selectedPayments) { const item = bucket(monthKey(stamp(row, 'paymentDate').toDate())); item.rentCollectedPaise = sum([item.rentCollectedPaise, money(row, 'amountPaise')]); }
  for (const row of selectedExpenses) { const item = bucket(monthKey(stamp(row, 'expenseDate').toDate())); item.propertyExpensesPaise = sum([item.propertyExpensesPaise, money(row, 'amountPaise')]); }
  const keys = [...months.keys()].sort();
  const first = filters.from ? monthKey(filters.from) : keys[0];
  const last = filters.through ? monthKey(filters.through) : keys[keys.length - 1];
  if (!first || !last) return [];
  const result: MonthlyCashFlowRow[] = [];
  for (let key = first; key <= last; key = nextMonth(key)) {
    if (result.length >= 120) throw new Error('Monthly trend exceeds 120 months; narrow the reporting range.');
    const row = bucket(key);
    result.push({ ...row, netCashFlowPaise: sum([row.rentCollectedPaise, -row.propertyExpensesPaise]) });
  }
  return result;
}
