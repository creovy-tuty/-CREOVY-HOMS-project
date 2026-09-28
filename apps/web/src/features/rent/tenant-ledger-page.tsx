import { useEffect, useMemo, useState } from 'react';
import { EmptyState, SectionCard, Skeleton } from '../../design/components';
import { formatDate, formatINR } from '../../design/tokens';
import { listenProperties, listenAllUnits, type Property, type Unit } from '../properties/property-repository';
import { listenTenants, type Tenant } from '../tenants/tenant-repository';
import { listWorkspaceLedger, listWorkspaceReceipts, type RentLedgerEntry, type RentReceipt } from './financial-record-repository';

export function TenantLedgerPage({ workspaceId, initialTenantId, viewReceipt }: { workspaceId: string; initialTenantId?: string | null; viewReceipt: (paymentId: string) => void }) {
  const [entries, setEntries] = useState<RentLedgerEntry[] | null>(null);
  const [receipts, setReceipts] = useState<RentReceipt[] | null>(null);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [properties, setProperties] = useState<Property[]>([]);
  const [units, setUnits] = useState<Unit[]>([]);
  const [tenantId, setTenantId] = useState(initialTenantId ?? 'all');
  const [propertyId, setPropertyId] = useState('all');
  const [period, setPeriod] = useState('all');
  const [search, setSearch] = useState('');
  const [error, setError] = useState('');
  const [revision, setRevision] = useState(0);
  useEffect(() => setTenantId(initialTenantId ?? 'all'), [initialTenantId]);
  useEffect(() => {
    let active = true;
    setEntries(null); setReceipts(null); setError('');
    Promise.all([listWorkspaceLedger(workspaceId), listWorkspaceReceipts(workspaceId)]).then(([ledger, snapshots]) => {
      if (active) { setEntries(ledger); setReceipts(snapshots); }
    }).catch(() => { if (active) setError('Tenant ledger could not be loaded.'); });
    return () => { active = false; };
  }, [workspaceId, revision]);
  useEffect(() => listenTenants(workspaceId, setTenants, () => setError('Tenant context could not be loaded.')), [workspaceId, revision]);
  useEffect(() => listenProperties(workspaceId, setProperties, () => setError('Property context could not be loaded.')), [workspaceId, revision]);
  useEffect(() => listenAllUnits(workspaceId, setUnits, () => setError('Unit context could not be loaded.')), [workspaceId, revision]);
  const receiptByPayment = useMemo(() => new Map((receipts ?? []).map(item => [item.paymentId, item])), [receipts]);
  const periodOptions = [...new Set((entries ?? []).map(item => item.periodKey))].sort().reverse();
  const selectedEntries = (entries ?? []).filter(item => tenantId === 'all' || item.tenantId === tenantId);
  const selectedTotal = selectedEntries.reduce((sum, item) => sum + item.amountPaise, 0);
  const filtered = selectedEntries.filter(item => {
    const receipt = receiptByPayment.get(item.paymentId);
    const tenant = receipt?.tenantName ?? tenants.find(value => value.id === item.tenantId)?.fullName ?? '';
    const property = receipt?.propertyName ?? properties.find(value => value.id === item.propertyId)?.name ?? '';
    const unit = receipt?.unitName ?? units.find(value => value.id === item.unitId)?.name ?? '';
    return (propertyId === 'all' || item.propertyId === propertyId) && (period === 'all' || item.periodKey === period) && `${tenant} ${property} ${unit} ${item.description} ${receipt?.receiptNumber ?? ''}`.toLowerCase().includes(search.toLowerCase());
  });
  return <div className="space-y-6"><div><p className="text-sm text-slate-500">Recorded transactions · rent payments only</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Tenant Ledger</h1><p className="mt-2 text-sm text-slate-500">Read-only payment history. Outstanding rent is tracked separately in Rent Collection.</p></div>
    <div className="grid gap-4 sm:grid-cols-2"><div className="rounded-2xl border border-slate-200 bg-white p-5"><p className="text-sm text-slate-500">Total Rent Payments Recorded</p>{entries === null ? <Skeleton className="mt-3 h-8 w-32" /> : <p className="mt-3 text-2xl font-semibold tabular-nums">{formatINR(selectedTotal)}</p>}</div><div className="rounded-2xl border border-slate-200 bg-white p-5"><p className="text-sm text-slate-500">Number of Transactions</p>{entries === null ? <Skeleton className="mt-3 h-8 w-16" /> : <p className="mt-3 text-2xl font-semibold tabular-nums">{selectedEntries.length}</p>}</div></div>
    <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 xl:grid-cols-4"><input aria-label="Search ledger" value={search} onChange={event => setSearch(event.target.value)} placeholder="Search tenant or transaction" className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm" /><select aria-label="Tenant filter" value={tenantId} onChange={event => setTenantId(event.target.value)} className="rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm"><option value="all">All tenants</option>{tenants.map(item => <option key={item.id} value={item.id}>{item.fullName}</option>)}</select><select aria-label="Property filter" value={propertyId} onChange={event => setPropertyId(event.target.value)} className="rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm"><option value="all">All properties</option>{properties.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select><select aria-label="Period filter" value={period} onChange={event => setPeriod(event.target.value)} className="rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm"><option value="all">All periods</option>{periodOptions.map(item => <option key={item} value={item}>{item}</option>)}</select></div>
    {error ? <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">{error} <button className="font-semibold underline" onClick={() => setRevision(value => value + 1)}>Retry</button></div> : entries === null || receipts === null ? <Skeleton className="h-48" /> : filtered.length === 0 ? <EmptyState title="No rent transactions recorded yet." body="Recorded rent payments will appear in this read-only ledger." /> : <SectionCard title={`${filtered.length} Transactions`}><div className="overflow-x-auto"><table className="w-full min-w-[900px] text-left text-sm"><thead className="border-b border-slate-100 text-xs uppercase tracking-wide text-slate-400"><tr>{['Date', 'Tenant', 'Property / Unit', 'Period', 'Description', 'Mode', 'Amount', 'Receipt'].map(label => <th key={label} className="pb-3 pr-4">{label}</th>)}</tr></thead><tbody>{filtered.map(item => { const receipt = receiptByPayment.get(item.paymentId); const tenant = receipt?.tenantName ?? tenants.find(value => value.id === item.tenantId)?.fullName ?? 'Tenant'; const property = receipt?.propertyName ?? properties.find(value => value.id === item.propertyId)?.name ?? 'Property'; const unit = receipt?.unitName ?? units.find(value => value.id === item.unitId)?.name ?? 'Unit'; return <tr key={item.id} className="border-b border-slate-100 last:border-0"><td className="py-4 pr-4 whitespace-nowrap">{formatDate(item.transactionDate.toDate())}</td><td className="pr-4 font-semibold">{tenant}</td><td className="pr-4">{property}<br /><span className="text-xs text-slate-500">{unit}</span></td><td className="pr-4">{item.periodKey}</td><td className="pr-4">{item.description}</td><td className="pr-4 capitalize">{item.paymentMode.replace('_', ' ')}</td><td className="pr-4 font-semibold tabular-nums">{formatINR(item.amountPaise)}</td><td className="pr-4">{receipt ? <button className="font-semibold text-brand" onClick={() => viewReceipt(item.paymentId)}>{receipt.receiptNumber}</button> : <span className="text-slate-400">Unavailable</span>}</td></tr>; })}</tbody></table></div></SectionCard>}
  </div>;
}
