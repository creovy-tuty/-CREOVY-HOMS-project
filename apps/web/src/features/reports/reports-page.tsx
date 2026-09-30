import { useEffect, useMemo, useState } from 'react';
import { createPortal } from 'react-dom';
import type { PortfolioSummary, PropertyPerformanceRow, MonthlyCashFlowRow, ReportRentRow, RentReport, TenantRentReport } from '@creovy/contracts';
import { Button, EmptyState, SectionCard, Skeleton, StatusChip, ToastNotice } from '../../design/components';
import { formatINR } from '../../design/tokens';
import { listenAllUnits, listenProperties, type Property, type Unit } from '../properties/property-repository';
import { getMonthlyCashFlowTrend, getPortfolioSummary, getPropertyPerformance, getRentBreakdown, getRentReport,
  getTenantRentReport, getAgreementRentReport, type WebReportFilters } from './report-repository';
import { ReportPrint, reportExportOptions, reportFileName, reportHasData, type ReportExportKind, type ReportPrintData } from './report-print';

const dateText = (date: Date) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' }).format(date);
const currentMonth = () => {
  const today = dateText(new Date());
  return { from: `01/${today.slice(3)}`, through: today, propertyId: '', unitId: '' };
};
type Draft = ReturnType<typeof currentMonth>;
function parseDate(value: string): Date | null {
  const match = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(value.trim());
  if (!match) return null;
  const day = Number(match[1]), month = Number(match[2]), year = Number(match[3]);
  const test = new Date(Date.UTC(year, month - 1, day));
  return test.getUTCDate() === day && test.getUTCMonth() === month - 1 && test.getUTCFullYear() === year
    ? new Date(test.getTime() - 19800000) : null;
}
const inputClass = 'w-full rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm outline-none focus:border-brand focus:ring-2 focus:ring-brand/10';
const labelClass = 'mb-1.5 block text-xs font-semibold uppercase tracking-wide text-slate-500';
function Kpi({ label, value, note }: { label: string; value: string; note?: string }) {
  return <div className="min-w-0 rounded-2xl border border-slate-200 bg-white px-4 py-3.5">
    <p className="text-xs font-medium text-slate-500">{label}</p><p className="mt-1.5 truncate text-xl font-semibold tracking-tight text-ink" title={value}>{value}</p>
    {note && <p className="mt-1 text-xs text-slate-400">{note}</p>}
  </div>;
}
function MiniValues({ items }: { items: { label: string; value: string }[] }) {
  return <div className="grid gap-2 sm:grid-cols-2 xl:grid-cols-4">{items.map(item => <div key={item.label} className="rounded-xl bg-slate-50 px-3 py-3"><p className="text-xs text-slate-500">{item.label}</p><p className="mt-1 text-sm font-semibold tabular-nums">{item.value}</p></div>)}</div>;
}
function MonthlyTrend({ rows }: { rows: MonthlyCashFlowRow[] }) {
  if (!rows.length) return <EmptyState title="No monthly activity" body="Choose a period with rent dues, payments, or expenses." />;
  const series = [
    { key: 'expectedRentPaise', label: 'Expected', color: 'bg-violet-300' },
    { key: 'rentCollectedPaise', label: 'Collected', color: 'bg-brand' },
    { key: 'propertyExpensesPaise', label: 'Expenses', color: 'bg-amber-400' },
    { key: 'netCashFlowPaise', label: 'Net cash', color: 'bg-teal-600' },
  ] as const;
  const maximum = Math.max(1, ...rows.flatMap(row => series.map(item => Math.abs(row[item.key]))));
  return <div>
    <div className="mb-4 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-600">{series.map(item => <span key={item.key} className="inline-flex items-center gap-1.5"><span className={`h-2.5 w-2.5 rounded-sm ${item.color}`} />{item.label}</span>)}</div>
    <div className="overflow-x-auto pb-2"><div className="flex min-w-max gap-2">{rows.map(row => <div key={row.periodKey} className="w-36 rounded-xl border border-slate-100 bg-slate-50/60 p-3">
      <p className="mb-3 text-xs font-semibold text-slate-600">{row.periodKey}</p>
      {series.map(item => <div key={item.key} className="mb-2" title={`${item.label}: ${formatINR(row[item.key])}`}>
        <div className="mb-0.5 flex justify-between gap-1 text-[10px] text-slate-500"><span>{item.label}</span><span className="tabular-nums">{formatINR(row[item.key])}</span></div>
        <div className="h-1.5 rounded-full bg-slate-200"><div className={`h-1.5 rounded-full ${item.color}`} style={{ width: `${Math.abs(row[item.key]) / maximum * 100}%` }} /></div>
      </div>)}
    </div>)}</div></div>
    <p className="mt-2 text-xs text-slate-400">Bar lengths compare absolute amounts; signed net cash values remain visible above.</p>
  </div>;
}
function reportError(cause: unknown) {
  const message = cause instanceof Error ? cause.message : 'Unable to load reports.';
  return message.includes('client reporting limit') ? 'This report is too large for on-device reporting. Narrow the date range or property filter.' : message;
}
export function ReportsPage({ workspaceId, onOpenProperty, onOpenTenant }: {
  workspaceId: string; onOpenProperty: (propertyId: string) => void; onOpenTenant: (tenantId: string) => void;
}) {
  const [draft, setDraft] = useState<Draft>(currentMonth);
  const [applied, setApplied] = useState<Draft>(currentMonth);
  const [rentStatusDraft, setRentStatusDraft] = useState('');
  const [rentStatus, setRentStatus] = useState('');
  const [properties, setProperties] = useState<Property[]>([]);
  const [units, setUnits] = useState<Unit[]>([]);
  const [contextError, setContextError] = useState('');
  const [filterError, setFilterError] = useState('');
  const [summary, setSummary] = useState<PortfolioSummary | null>(null);
  const [rent, setRent] = useState<RentReport | null>(null);
  const [breakdown, setBreakdown] = useState<ReportRentRow[]>([]);
  const [performance, setPerformance] = useState<PropertyPerformanceRow[]>([]);
  const [trend, setTrend] = useState<MonthlyCashFlowRow[]>([]);
  const [selectedTenant, setSelectedTenant] = useState<string | null>(null);
  const [selectedAgreement, setSelectedAgreement] = useState<string | null>(null);
  const [tenantReport, setTenantReport] = useState<TenantRentReport | null>(null);
  const [historyLoadedKey, setHistoryLoadedKey] = useState<string | null>(null);
  const [tenantError, setTenantError] = useState('');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [revision, setRevision] = useState(0);
  const [exportKind, setExportKind] = useState<ReportExportKind>('overview');
  const [exportNotice, setExportNotice] = useState('');
  const [printData, setPrintData] = useState<ReportPrintData | null>(null);
  useEffect(() => {
    const unsubscribeProperties = listenProperties(workspaceId, setProperties, error => setContextError(error.message));
    const unsubscribeUnits = listenAllUnits(workspaceId, setUnits, error => setContextError(error.message));
    return () => { unsubscribeProperties(); unsubscribeUnits(); };
  }, [workspaceId]);
  const filters = useMemo<WebReportFilters>(() => ({
    from: parseDate(applied.from) ?? undefined, through: parseDate(applied.through) ?? undefined,
    propertyId: applied.propertyId || undefined, unitId: applied.unitId || undefined,
  }), [applied]);
  useEffect(() => {
    let live = true;
    setLoading(true); setError('');
    const rentFilters: WebReportFilters = { ...filters, rentStatus: rentStatus ? rentStatus as WebReportFilters['rentStatus'] : undefined };
    Promise.all([
      getPortfolioSummary(workspaceId, filters), getRentReport(workspaceId, rentFilters),
      getRentBreakdown(workspaceId, rentFilters), getPropertyPerformance(workspaceId, filters),
      getMonthlyCashFlowTrend(workspaceId, filters),
    ]).then(([nextSummary, nextRent, nextBreakdown, nextPerformance, nextTrend]) => {
      if (!live) return;
      setSummary(nextSummary); setRent(nextRent); setBreakdown(nextBreakdown);
      setPerformance(nextPerformance); setTrend(nextTrend); setLoading(false);
    }).catch(cause => { if (live) { setError(reportError(cause)); setLoading(false); } });
    return () => { live = false; };
  }, [workspaceId, filters, rentStatus, revision]);
  useEffect(() => {
    if (!selectedTenant) { setTenantReport(null); setHistoryLoadedKey(null); return; }
    let live = true;
    const key = selectedAgreement ? `agreement:${selectedAgreement}` : `tenant:${selectedTenant}`;
    setTenantError(''); setTenantReport(null); setHistoryLoadedKey(null);
    (selectedAgreement ? getAgreementRentReport(workspaceId, selectedAgreement, filters) :
      getTenantRentReport(workspaceId, selectedTenant, filters)).then(result => { if (live) { setTenantReport(result); setHistoryLoadedKey(key); } })
      .catch(cause => { if (live) setTenantError(reportError(cause)); });
    return () => { live = false; };
  }, [workspaceId, selectedTenant, selectedAgreement, filters, revision]);
  useEffect(() => {
    if (!printData) return;
    const originalTitle = document.title;
    document.title = reportFileName(printData).replace(/\.pdf$/, '');
    const finish = () => { document.title = originalTitle; setPrintData(null); };
    window.addEventListener('afterprint', finish);
    const frame = window.requestAnimationFrame(() => window.print());
    return () => { window.cancelAnimationFrame(frame); window.removeEventListener('afterprint', finish); document.title = originalTitle; };
  }, [printData]);
  const apply = () => {
    const from = parseDate(draft.from), through = parseDate(draft.through);
    if (!from || !through || from.getTime() > through.getTime()) { setFilterError('Enter a valid DD/MM/YYYY range with the start on or before the end.'); return; }
    setFilterError(''); setSelectedTenant(null); setSelectedAgreement(null); setApplied({ ...draft }); setRentStatus(rentStatusDraft); setRevision(value => value + 1);
  };
  const clear = () => { const reset = currentMonth(); setDraft(reset); setApplied(reset); setRentStatusDraft(''); setRentStatus(''); setSelectedTenant(null); setSelectedAgreement(null); setFilterError(''); setRevision(value => value + 1); };
  const visibleUnits = units.filter(unit => !draft.propertyId || unit.propertyId === draft.propertyId);
  const rentRows = breakdown;
  const s = summary;
  const startPrint = () => {
    if (printData || loading || error || !s || !rent) return;
    if (contextError || applied.propertyId && !properties.some(item => item.id === applied.propertyId) || applied.unitId && !units.some(item => item.id === applied.unitId)) {
      setExportNotice('Report context is incomplete. Reload the page before exporting.'); return;
    }
    if (exportKind === 'history' && (tenantError || !selectedTenant || !tenantReport || tenantReport.tenantId !== selectedTenant || historyLoadedKey !== (selectedAgreement ? `agreement:${selectedAgreement}` : `tenant:${selectedTenant}`))) {
      setExportNotice('Open a tenant or agreement history and wait for it to load before exporting.'); return;
    }
    const generated = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date());
    const next: ReportPrintData = {
      kind: exportKind, from: applied.from, through: applied.through,
      propertyName: properties.find(item => item.id === applied.propertyId)?.name ?? 'All properties',
      unitName: units.find(item => item.id === applied.unitId)?.name ?? 'All units',
      rentStatus: rentStatus ? rentStatus[0].toUpperCase() + rentStatus.slice(1) : '', generatedAt: generated,
      summary: s, rent, rows: rentRows, performance, trend,
      history: exportKind === 'history' ? tenantReport : null, historyScope: selectedAgreement ? 'agreement' : 'tenant',
      propertyNames: Object.fromEntries(properties.map(item => [item.id, item.name])),
      unitNames: Object.fromEntries(units.map(item => [item.id, item.name])),
    };
    if (!reportHasData(next)) { setExportNotice('No records exist for this report and selected scope. Adjust the filters before exporting.'); return; }
    setExportNotice(''); setPrintData(next);
  };
  return <div className="space-y-5">
    <header className="flex flex-wrap items-end justify-between gap-3"><div><p className="text-xs font-semibold uppercase tracking-[.16em] text-brand">Portfolio intelligence</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Reports & Analytics</h1><p className="mt-1 text-sm text-slate-500">Read-only insights from your live workspace records.</p></div><div className="flex flex-wrap items-center gap-2"><span className="rounded-full border border-slate-200 bg-white px-3 py-1.5 text-xs text-slate-500">Asia/Kolkata · INR</span><select aria-label="Report to export" className="rounded-xl border border-slate-200 bg-white px-3 py-2 text-sm" value={exportKind} onChange={event => { setExportKind(event.target.value as ReportExportKind); setExportNotice(''); }}>{reportExportOptions.map(option => <option key={option.kind} value={option.kind}>{option.label}</option>)}</select><Button variant="outline" onClick={startPrint} disabled={loading || !!error || !!printData || !s || !rent}>Print / Save PDF</Button></div></header>
    {exportNotice && <p role="status" className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-2 text-sm text-amber-900">{exportNotice}</p>}
    {printData && createPortal(<ReportPrint data={printData} />, document.body)}
    <section className="sticky top-16 z-10 rounded-2xl border border-slate-200 bg-white/95 p-4 shadow-sm backdrop-blur" aria-label="Report filters">
      <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-[1fr_1fr_1.2fr_1.2fr_1fr_auto] xl:items-end">
        <label><span className={labelClass}>From · DD/MM/YYYY</span><input className={inputClass} value={draft.from} onChange={event => setDraft(value => ({ ...value, from: event.target.value }))} inputMode="numeric" aria-label="From date" /></label>
        <label><span className={labelClass}>Through · DD/MM/YYYY</span><input className={inputClass} value={draft.through} onChange={event => setDraft(value => ({ ...value, through: event.target.value }))} inputMode="numeric" aria-label="Through date" /></label>
        <label><span className={labelClass}>Property</span><select className={inputClass} value={draft.propertyId} onChange={event => setDraft(value => ({ ...value, propertyId: event.target.value, unitId: '' }))}><option value="">All properties</option>{properties.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
        <label><span className={labelClass}>Unit</span><select className={inputClass} value={draft.unitId} onChange={event => setDraft(value => ({ ...value, unitId: event.target.value }))}><option value="">All units</option>{visibleUnits.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label>
        <label><span className={labelClass}>Rent status</span><select className={inputClass} value={rentStatusDraft} onChange={event => setRentStatusDraft(event.target.value)}><option value="">All statuses</option>{['pending', 'partial', 'paid', 'overdue'].map(item => <option key={item} value={item}>{item[0].toUpperCase() + item.slice(1)}</option>)}</select></label>
        <div className="flex gap-2"><Button onClick={apply}>Apply</Button><Button variant="outline" onClick={clear}>Reset</Button></div>
      </div>
      {filterError && <p role="alert" className="mt-2 text-sm text-red-700">{filterError}</p>}
      {contextError && <p role="alert" className="mt-2 text-sm text-red-700">Filter choices may be incomplete: {contextError}</p>}
    </section>
    {loading ? <div className="space-y-4" aria-label="Loading reports"><div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">{Array.from({ length: 7 }, (_, index) => <Skeleton key={index} className="h-24" />)}</div><Skeleton className="h-60" /><Skeleton className="h-44" /></div>
      : error ? <SectionCard title="Unable to load reports"><ToastNotice tone="danger" message={error} /><Button className="mt-4" onClick={() => setRevision(value => value + 1)}>Retry</Button></SectionCard>
    : s && rent ? <>
        <div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
          <Kpi label="Expected Rent" value={formatINR(s.rent.expectedRentPaise)} note="Due dates in selected period" />
          <Kpi label="Rent Collected" value={formatINR(s.rent.rentCollectedPaise)} note="Actual payment dates" />
          <Kpi label="Rent Outstanding" value={formatINR(s.rent.outstandingPaise)} note="Current due balances" />
          <Kpi label="Rent Overdue" value={formatINR(s.rent.overduePaise)} note={`As of ${s.rent.asOfBusinessDate}`} />
          <Kpi label="Property Expenses" value={formatINR(s.expenses.totalExpensesPaise)} />
          <Kpi label="Net Property Cash Flow" value={formatINR(s.netPropertyCashFlowPaise)} note="Rent collected − property expenses" />
          <Kpi label="Occupancy Rate" value={`${s.occupancy.occupancyRatePercent.toFixed(2)}%`} note="Current rentable inventory" />
        </div>
        <SectionCard title="Rent report" action={<span className="text-xs text-slate-500">Due-date view · {rent.dueCount} dues</span>}>
          <MiniValues items={[{ label: 'Expected', value: formatINR(rent.expectedRentPaise) }, { label: 'Collected', value: formatINR(rent.rentCollectedPaise) }, { label: 'Outstanding', value: formatINR(rent.outstandingPaise) }, { label: 'Overdue', value: formatINR(rent.overduePaise) }, { label: 'Collection rate', value: `${rent.collectionRatePercent.toFixed(2)}%` }]} />
          <p className="mt-3 text-xs text-slate-500">Collection rate uses payments in the selected cash period linked to selected dues. Current balances may differ from period cash receipts.</p>
          <div className="mt-4 overflow-x-auto">{rentRows.length ? <table className="w-full min-w-[940px] text-left text-sm"><thead className="text-xs uppercase tracking-wide text-slate-400"><tr>{['Property / Unit', 'Tenant', 'Period / Agreement', 'Due date', 'Expected', 'Paid to date', 'Balance', 'Status'].map(item => <th key={item} className="pb-2 pr-3 font-semibold">{item}</th>)}</tr></thead><tbody>{rentRows.map(row => <tr key={row.dueId} className="border-t border-slate-100"><td className="py-3 pr-3"><button className="font-semibold text-brand hover:underline" onClick={() => onOpenProperty(row.propertyId)}>{row.propertyName}</button><p className="text-xs text-slate-500">{row.unitName}</p></td><td className="pr-3"><button className="font-medium hover:text-brand" onClick={() => { setSelectedAgreement(null); setSelectedTenant(row.tenantId); }}>{row.tenantName}</button></td><td className="pr-3"><button className="text-brand hover:underline" onClick={() => { setSelectedAgreement(row.agreementId); setSelectedTenant(row.tenantId); }}>{row.periodKey}<span className="block text-[10px]">View agreement history</span></button></td><td className="pr-3">{dateText((row.dueDate as { toDate: () => Date }).toDate())}</td><td className="pr-3 tabular-nums">{formatINR(row.expectedPaise)}</td><td className="pr-3 tabular-nums">{formatINR(row.paidPaise)}</td><td className="pr-3 tabular-nums">{formatINR(row.balancePaise)}</td><td><StatusChip status={(row.status[0].toUpperCase() + row.status.slice(1)) as 'Paid' | 'Partial' | 'Pending' | 'Overdue'} /></td></tr>)}</tbody></table> : <EmptyState title="No rent dues in this view" body="Try a different period, property, unit, or status." />}</div>
        </SectionCard>
        {selectedTenant && <SectionCard title={selectedAgreement ? 'Agreement rent history' : 'Tenant rent history'} action={<Button variant="ghost" onClick={() => { setSelectedTenant(null); setSelectedAgreement(null); }}>Close</Button>}>
          {tenantError ? <ToastNotice tone="danger" message={tenantError} /> : !tenantReport ? <Skeleton className="h-28" /> : <div className="space-y-3">
            <div className="flex flex-wrap items-center justify-between gap-2"><div><p className="font-semibold">{tenantReport.tenantName}</p><p className="text-xs text-slate-500">{tenantReport.dues.length} dues · {tenantReport.payments.length} payments in selected periods</p></div><Button variant="outline" onClick={() => onOpenTenant(selectedTenant)}>View tenant & agreements</Button></div>
            <MiniValues items={[{ label: 'Expected', value: formatINR(tenantReport.rent.expectedRentPaise) }, { label: 'Paid in period', value: formatINR(tenantReport.rent.rentCollectedPaise) }, { label: 'Outstanding', value: formatINR(tenantReport.rent.outstandingPaise) }]} />
            <div className="overflow-x-auto"><table className="w-full min-w-[690px] text-left text-xs"><thead className="text-slate-500"><tr>{['Agreement', 'Property / Unit', 'Period', 'Expected', 'Paid to date', 'Outstanding'].map(label => <th className="pb-2 pr-3" key={label}>{label}</th>)}</tr></thead><tbody>{rentRows.filter(row => row.tenantId === selectedTenant && (!selectedAgreement || row.agreementId === selectedAgreement)).map(row => <tr className="border-t border-slate-100" key={row.dueId}><td className="py-2 pr-3">{row.agreementId.slice(0, 8)}…</td><td className="pr-3">{row.propertyName} · {row.unitName}</td><td className="pr-3">{row.periodKey}</td><td className="pr-3">{formatINR(row.expectedPaise)}</td><td className="pr-3">{formatINR(row.paidPaise)}</td><td>{formatINR(row.balancePaise)}</td></tr>)}</tbody></table></div>
            <div className="grid gap-3 lg:grid-cols-2"><div><p className="mb-2 text-sm font-semibold">Dues</p>{tenantReport.dues.length ? tenantReport.dues.map(item => <p key={item.id} className="border-t border-slate-100 py-2 text-xs">{item.periodKey} · {formatINR(item.amountPaise)} expected · {formatINR(item.balancePaise)} balance</p>) : <p className="text-xs text-slate-500">No dues.</p>}</div><div><p className="mb-2 text-sm font-semibold">Payments</p>{tenantReport.payments.length ? tenantReport.payments.map(item => <p key={item.id} className="border-t border-slate-100 py-2 text-xs">{item.periodKey} · {formatINR(item.amountPaise)} · {dateText((item.date as { toDate: () => Date }).toDate())}</p>) : <p className="text-xs text-slate-500">No payments.</p>}</div></div>
          </div>}
        </SectionCard>}
        <SectionCard title="Monthly cash flow trend"><MonthlyTrend rows={trend} /></SectionCard>
        <SectionCard title="Property performance">
          {performance.length ? <div className="overflow-x-auto"><table className="w-full min-w-[810px] text-left text-sm"><thead className="text-xs uppercase text-slate-400"><tr>{['Property', 'Expected', 'Collected', 'Outstanding', 'Expenses', 'Net cash', 'Occupancy'].map(item => <th key={item} className="pb-2 pr-3">{item}</th>)}</tr></thead><tbody>{performance.map(row => <tr key={row.propertyId} className="border-t border-slate-100"><td className="py-3 pr-3"><button className="font-semibold text-brand hover:underline" onClick={() => onOpenProperty(row.propertyId)}>{row.propertyName}</button></td><td className="pr-3">{formatINR(row.expectedRentPaise)}</td><td className="pr-3">{formatINR(row.rentCollectedPaise)}</td><td className="pr-3">{formatINR(row.outstandingPaise)}</td><td className="pr-3">{formatINR(row.propertyExpensesPaise)}</td><td className="pr-3">{formatINR(row.netCashFlowPaise)}</td><td>{row.occupancyRatePercent.toFixed(2)}% <span className="text-xs text-slate-400">({row.occupiedUnits}/{row.totalRentableUnits})</span></td></tr>)}</tbody></table></div> : <EmptyState title="No properties in this view" body="Choose another property or unit filter." />}
        </SectionCard>
        <div className="grid gap-4 xl:grid-cols-2">
          <SectionCard title="Property expenses"><MiniValues items={[{ label: 'Total', value: formatINR(s.expenses.totalExpensesPaise) }, { label: 'Expense count', value: String(s.expenses.expenseCount) }]} /><p className="mb-2 mt-4 text-xs font-semibold uppercase text-slate-500">By category</p>{s.expenses.byCategory.length ? s.expenses.byCategory.map(item => <div key={item.key} className="flex justify-between border-t border-slate-100 py-2 text-sm"><span className="capitalize">{item.key.replaceAll('_', ' ')}</span><span className="font-semibold">{formatINR(item.amountPaise)}</span></div>) : <EmptyState title="No expenses" body="No property expenses match these filters." />}<p className="mb-2 mt-4 text-xs font-semibold uppercase text-slate-500">By property</p>{s.expenses.byProperty.map(item => <div key={item.key} className="flex justify-between border-t border-slate-100 py-2 text-sm"><span>{properties.find(property => property.id === item.key)?.name ?? item.key}</span><span className="font-semibold">{formatINR(item.amountPaise)}</span></div>)}</SectionCard>
          <SectionCard title="Bills & Taxes · separate tracking"><MiniValues items={[{ label: 'Raised', value: formatINR(s.bills.billsRaisedPaise) }, { label: 'Paid', value: formatINR(s.bills.billsPaidPaise) }, { label: 'Outstanding', value: formatINR(s.bills.billsOutstandingPaise) }, { label: 'Overdue', value: formatINR(s.bills.billsOverduePaise) }]} /><p className="mb-2 mt-4 text-xs font-semibold uppercase text-slate-500">Payments by bill type</p>{s.bills.paymentsByBillType.length ? s.bills.paymentsByBillType.map(item => <div key={item.key} className="flex justify-between border-t border-slate-100 py-2 text-sm"><span className="capitalize">{item.key.replaceAll('_', ' ')}</span><span className="font-semibold">{formatINR(item.amountPaise)}</span></div>) : <EmptyState title="No bill payments" body="No bill payments match these filters." />}</SectionCard>
          <SectionCard title="Security deposits · separate funds"><MiniValues items={[{ label: 'Agreed', value: formatINR(s.deposits.depositAgreedPaise) }, { label: 'Received', value: formatINR(s.deposits.depositReceivedPaise) }, { label: 'Refunded', value: formatINR(s.deposits.depositRefundedPaise) }, { label: 'Currently held', value: formatINR(s.deposits.depositCurrentlyHeldPaise) }]} /><p className="mt-4 text-xs text-slate-500">Security deposits are tracked separately and are not counted as rental income or Net Property Cash Flow. Agreed and held are current balances; received and refunded follow transaction dates.</p></SectionCard>
          <SectionCard title="Occupancy & agreements"><MiniValues items={[{ label: 'Rentable units', value: String(s.occupancy.totalRentableUnits) }, { label: 'Occupied', value: String(s.occupancy.occupiedUnits) }, { label: 'Vacant', value: String(s.occupancy.vacantUnits) }, { label: 'Maintenance', value: String(s.occupancy.maintenanceUnits) }, { label: 'Occupancy rate', value: `${s.occupancy.occupancyRatePercent.toFixed(2)}%` }]} /><p className="mt-3 text-xs text-slate-500">Inactive units ({s.occupancy.inactiveUnits}) and maintenance units are excluded from rentable inventory.</p><div className="mt-4"><MiniValues items={[{ label: 'Active tenants', value: String(s.occupancy.activeTenants) }, { label: 'Active agreements', value: String(s.occupancy.activeAgreements) }, { label: 'Upcoming agreements', value: String(s.occupancy.upcomingAgreements) }, { label: 'Ended agreements', value: String(s.occupancy.endedAgreements) }]} /></div></SectionCard>
        </div>
        <p className="pb-5 text-xs text-slate-400">Current balances and occupancy are live snapshots, not historic as-of balances. Use Print / Save PDF and choose Save as PDF in your browser print dialog. CSV/Excel export is not available.</p>
      </>}
  </div>;
}
