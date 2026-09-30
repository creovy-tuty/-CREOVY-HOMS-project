import type { ReactNode } from 'react';
import type { MonthlyCashFlowRow, PortfolioSummary, PropertyPerformanceRow, RentReport, ReportRentRow, TenantRentReport } from '@creovy/contracts';
import { formatINR } from '../../design/tokens';
import './report-print.css';

export type ReportExportKind = 'overview' | 'rent' | 'property' | 'expenses' | 'bills' | 'deposits' | 'occupancy' | 'history';
export const reportExportOptions: { kind: ReportExportKind; label: string; slug: string }[] = [
  { kind: 'overview', label: 'Portfolio overview', slug: 'Portfolio' },
  { kind: 'rent', label: 'Rent collection', slug: 'Rent' },
  { kind: 'property', label: 'Property performance', slug: 'Property' },
  { kind: 'expenses', label: 'Property expenses', slug: 'Expense' },
  { kind: 'bills', label: 'Bills & Taxes', slug: 'Bills-Taxes' },
  { kind: 'deposits', label: 'Security deposits', slug: 'Security-Deposit' },
  { kind: 'occupancy', label: 'Occupancy', slug: 'Occupancy' },
  { kind: 'history', label: 'Tenant / agreement rent history', slug: 'Rent-History' },
];

export interface ReportPrintData {
  kind: ReportExportKind;
  from: string;
  through: string;
  propertyName: string;
  unitName: string;
  rentStatus: string;
  generatedAt: string;
  summary: PortfolioSummary;
  rent: RentReport;
  rows: ReportRentRow[];
  performance: PropertyPerformanceRow[];
  trend: MonthlyCashFlowRow[];
  history: TenantRentReport | null;
  historyScope: 'tenant' | 'agreement';
  propertyNames: Record<string, string>;
  unitNames: Record<string, string>;
}

export function reportHasData(data: ReportPrintData): boolean {
  const { summary: s, rent, kind, history } = data;
  switch (kind) {
    case 'overview': return s.rent.dueCount > 0 || s.rent.paymentCount > 0 || s.expenses.expenseCount > 0 || s.bills.billCount > 0 || s.bills.paymentCount > 0 || s.deposits.transactionCount > 0 || s.deposits.depositAgreedPaise > 0 || s.deposits.depositCurrentlyHeldPaise > 0 || s.occupancy.totalRentableUnits > 0 || s.occupancy.inactiveUnits > 0 || s.occupancy.activeTenants > 0 || data.performance.length > 0;
    case 'rent': return rent.dueCount > 0 || rent.paymentCount > 0;
    case 'property': return data.performance.length > 0;
    case 'expenses': return s.expenses.expenseCount > 0;
    case 'bills': return s.bills.billCount > 0 || s.bills.paymentCount > 0;
    case 'deposits': return s.deposits.transactionCount > 0 || s.deposits.depositAgreedPaise > 0 || s.deposits.depositCurrentlyHeldPaise > 0;
    case 'occupancy': return s.occupancy.totalRentableUnits > 0 || s.occupancy.inactiveUnits > 0 || s.occupancy.activeTenants > 0 || s.occupancy.activeAgreements > 0 || s.occupancy.upcomingAgreements > 0 || s.occupancy.endedAgreements > 0;
    case 'history': return !!history && (history.dues.length > 0 || history.payments.length > 0);
  }
}

export function reportFileName(data: ReportPrintData): string {
  const slug = reportExportOptions.find(option => option.kind === data.kind)!.slug;
  const start = `${data.from.slice(6)}-${data.from.slice(3, 5)}-${data.from.slice(0, 2)}`;
  const end = `${data.through.slice(6)}-${data.through.slice(3, 5)}-${data.through.slice(0, 2)}`;
  const lastDay = new Date(Date.UTC(Number(data.from.slice(6)), Number(data.from.slice(3, 5)), 0)).getUTCDate();
  const fullMonth = start.slice(0, 7) === end.slice(0, 7) && data.from.slice(0, 2) === '01' && Number(data.through.slice(0, 2)) === lastDay;
  const period = fullMonth ? start.slice(0, 7) : `${start}-to-${end}`;
  const property = data.propertyName === 'All properties' ? '' : data.propertyName.normalize('NFKD').replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 32).replace(/-$/, '');
  return `CREOVY-HOMS-${slug}-Report${property ? `-${property}` : ''}-${period}.pdf`;
}

const dateText = (value: { toDate: () => Date }) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' }).format(value.toDate());
const human = (value: string) => value.replaceAll('_', ' ').replace(/\b\w/g, letter => letter.toUpperCase());
function Metrics({ items }: { items: [string, string][] }) {
  return <dl className="report-metrics">{items.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl>;
}
function Table({ headings, rows }: { headings: string[]; rows: (string | number)[][] }) {
  if (!rows.length) return <p className="report-note">No breakdown rows match this part of the selected scope.</p>;
  return <table className="report-table"><thead><tr>{headings.map(heading => <th key={heading}>{heading}</th>)}</tr></thead><tbody>{rows.map((row, index) => <tr key={index}>{row.map((value, cell) => <td key={cell}>{value}</td>)}</tr>)}</tbody></table>;
}
function Section({ title, children }: { title: string; children: ReactNode }) {
  return <section className="report-section"><h2>{title}</h2>{children}</section>;
}
export function ReportPrint({ data }: { data: ReportPrintData }) {
  const { summary: s, rent, kind } = data;
  const title = reportExportOptions.find(option => option.kind === kind)!.label + ' report';
  const rentMetrics: [string, string][] = [['Expected rent', formatINR(rent.expectedRentPaise)], ['Rent collected', formatINR(rent.rentCollectedPaise)], ['Outstanding', formatINR(rent.outstandingPaise)], ['Overdue', formatINR(rent.overduePaise)], ['Collection rate', `${rent.collectionRatePercent.toFixed(2)}%`]];
  const occupancyMetrics: [string, string][] = [['Rentable units', String(s.occupancy.totalRentableUnits)], ['Occupied', String(s.occupancy.occupiedUnits)], ['Vacant', String(s.occupancy.vacantUnits)], ['Maintenance', String(s.occupancy.maintenanceUnits)], ['Inactive', String(s.occupancy.inactiveUnits)], ['Occupancy rate', `${s.occupancy.occupancyRatePercent.toFixed(2)}%`]];
  const performanceTable = <Table headings={['Property', 'Expected', 'Collected', 'Outstanding', 'Expenses', 'Net cash', 'Occupancy']} rows={data.performance.map(row => [row.propertyName, formatINR(row.expectedRentPaise), formatINR(row.rentCollectedPaise), formatINR(row.outstandingPaise), formatINR(row.propertyExpensesPaise), formatINR(row.netCashFlowPaise), `${row.occupancyRatePercent.toFixed(2)}% (${row.occupiedUnits}/${row.totalRentableUnits})`])} />;
  return <article className="creovy-report-print" aria-label={title}>
    <header className="report-heading"><p className="report-brand">CREOVY HOMS</p><h1>{title}</h1><p>Owner workspace report · Asia/Kolkata · INR</p></header>
    <div className="report-scope"><span><b>Period</b> {data.from} – {data.through}</span><span><b>Property</b> {data.propertyName}</span><span><b>Unit</b> {data.unitName}</span><span><b>Generated</b> {data.generatedAt}</span><span><b>Rent status</b> {kind === 'rent' ? (data.rentStatus || 'All statuses') : 'Not applied to this report'}</span>{kind === 'history' && <span><b>History scope</b> {data.historyScope === 'agreement' ? 'Selected agreement' : 'Selected tenant'}</span>}</div>
    {kind === 'overview' && <><Section title="Portfolio KPIs"><Metrics items={[["Expected rent", formatINR(s.rent.expectedRentPaise)], ["Rent collected", formatINR(s.rent.rentCollectedPaise)], ["Outstanding", formatINR(s.rent.outstandingPaise)], ["Overdue", formatINR(s.rent.overduePaise)], ["Property expenses", formatINR(s.expenses.totalExpensesPaise)], ["Net property cash flow", formatINR(s.netPropertyCashFlowPaise)], ["Occupancy rate", `${s.occupancy.occupancyRatePercent.toFixed(2)}%`]]} /></Section><Section title="Monthly cash flow"><Table headings={['Month', 'Expected', 'Collected', 'Expenses', 'Net cash']} rows={data.trend.map(row => [row.periodKey, formatINR(row.expectedRentPaise), formatINR(row.rentCollectedPaise), formatINR(row.propertyExpensesPaise), formatINR(row.netCashFlowPaise)])} /></Section>{data.performance.length > 0 && <Section title="Property performance">{performanceTable}</Section>}<Section title="Bills & Taxes · separate tracking"><Metrics items={[["Raised", formatINR(s.bills.billsRaisedPaise)], ["Paid", formatINR(s.bills.billsPaidPaise)], ["Outstanding", formatINR(s.bills.billsOutstandingPaise)]]} /></Section><Section title="Security deposits · separate funds"><Metrics items={[["Agreed", formatINR(s.deposits.depositAgreedPaise)], ["Received", formatINR(s.deposits.depositReceivedPaise)], ["Refunded", formatINR(s.deposits.depositRefundedPaise)], ["Held", formatINR(s.deposits.depositCurrentlyHeldPaise)]]} /></Section><p className="report-note">Security deposits and Bills & Taxes are tracked separately; neither is included in net property cash flow.</p></>}
    {kind === 'rent' && <><Section title="Rent collection KPIs"><Metrics items={rentMetrics} /><p className="report-note">Due-date view. Collection rate uses cash-period payments linked to selected dues; balances are current.</p></Section><Section title="Rent dues"><Table headings={['Property / Unit', 'Tenant', 'Period', 'Due date', 'Expected', 'Paid to date', 'Balance', 'Status']} rows={data.rows.map(row => [`${row.propertyName} / ${row.unitName}`, row.tenantName, row.periodKey, dateText(row.dueDate as { toDate: () => Date }), formatINR(row.expectedPaise), formatINR(row.paidPaise), formatINR(row.balancePaise), human(row.status)])} /></Section></>}
    {kind === 'property' && <Section title="Property performance">{performanceTable}</Section>}
    {kind === 'expenses' && <><Section title="Property expense KPIs"><Metrics items={[["Total expenses", formatINR(s.expenses.totalExpensesPaise)], ["Expense count", String(s.expenses.expenseCount)]]} /></Section><Section title="By category"><Table headings={['Category', 'Amount', 'Count']} rows={s.expenses.byCategory.map(item => [human(item.key), formatINR(item.amountPaise), item.count])} /></Section><Section title="By property"><Table headings={['Property', 'Amount', 'Count']} rows={s.expenses.byProperty.map(item => [data.propertyNames[item.key] ?? 'Property', formatINR(item.amountPaise), item.count])} /></Section>{s.expenses.byUnit.length > 0 && <Section title="By unit"><Table headings={['Unit', 'Amount', 'Count']} rows={s.expenses.byUnit.map(item => [data.unitNames[item.key] ?? 'Unit', formatINR(item.amountPaise), item.count])} /></Section>}<p className="report-note">Bills & Taxes and security deposits are excluded from property expenses.</p></>}
    {kind === 'bills' && <><Section title="Bills & Taxes KPIs"><Metrics items={[["Raised", formatINR(s.bills.billsRaisedPaise)], ["Paid", formatINR(s.bills.billsPaidPaise)], ["Outstanding", formatINR(s.bills.billsOutstandingPaise)], ["Overdue", formatINR(s.bills.billsOverduePaise)], ["Bill count", String(s.bills.billCount)], ["Payment count", String(s.bills.paymentCount)]]} /></Section><Section title="Payments by bill type"><Table headings={['Bill type', 'Amount', 'Count']} rows={s.bills.paymentsByBillType.map(item => [human(item.key), formatINR(item.amountPaise), item.count])} /></Section><p className="report-note">Bills & Taxes are manual tracking and separate from property expenses.</p></>}
    {kind === 'deposits' && <><Section title="Security deposit balances"><Metrics items={[["Agreed", formatINR(s.deposits.depositAgreedPaise)], ["Received", formatINR(s.deposits.depositReceivedPaise)], ["Refunded", formatINR(s.deposits.depositRefundedPaise)], ["Currently held", formatINR(s.deposits.depositCurrentlyHeldPaise)], ["Transaction count", String(s.deposits.transactionCount)]]} /></Section><p className="report-note">Security deposits are separate funds, not rental income or net property cash flow. Agreed and held are current balances; received and refunded follow transaction dates.</p></>}
    {kind === 'occupancy' && <><Section title="Current occupancy"><Metrics items={occupancyMetrics} /></Section><Section title="Tenants & agreements"><Metrics items={[["Active tenants", String(s.occupancy.activeTenants)], ["Active agreements", String(s.occupancy.activeAgreements)], ["Upcoming agreements", String(s.occupancy.upcomingAgreements)], ["Ended agreements", String(s.occupancy.endedAgreements)]]} /></Section><p className="report-note">Current snapshot, not historic occupancy as of the selected dates.</p></>}
    {kind === 'history' && data.history && <><Section title={data.history.tenantName}><Metrics items={[["Expected", formatINR(data.history.rent.expectedRentPaise)], ["Paid in period", formatINR(data.history.rent.rentCollectedPaise)], ["Outstanding", formatINR(data.history.rent.outstandingPaise)]]} /></Section><Section title="Rent dues"><Table headings={['Property / Unit', 'Period', 'Due date', 'Expected', 'Paid to date', 'Balance']} rows={data.history.dues.map(item => [`${data.propertyNames[item.propertyId] ?? 'Property'} / ${data.unitNames[item.unitId] ?? 'Unit'}`, item.periodKey, dateText(item.date as { toDate: () => Date }), formatINR(item.amountPaise), formatINR(item.paidPaise ?? 0), formatINR(item.balancePaise ?? 0)])} /></Section><Section title="Payment transactions"><Table headings={['Property / Unit', 'Period', 'Payment date', 'Amount']} rows={data.history.payments.map(item => [`${data.propertyNames[item.propertyId] ?? 'Property'} / ${data.unitNames[item.unitId] ?? 'Unit'}`, item.periodKey, dateText(item.date as { toDate: () => Date }), formatINR(item.amountPaise)])} /></Section></>}
    <footer className="report-footer">CREOVY HOMS · Generated from authorized workspace report data · {data.generatedAt}</footer>
  </article>;
}
