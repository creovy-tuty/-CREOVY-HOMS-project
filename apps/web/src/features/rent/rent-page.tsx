import { useEffect, useMemo, useRef, useState } from 'react';
import { doc, onSnapshot } from 'firebase/firestore';
import { Button, EmptyState, SectionCard, Skeleton, StatusChip } from '../../design/components';
import { formatDate, formatINR } from '../../design/tokens';
import { auth, db } from '../../lib/firebase';
import { listenProperties, listenAllUnits, type Property, type Unit } from '../properties/property-repository';
import { listenAgreements, listenTenants, type Agreement, type Tenant } from '../tenants/tenant-repository';
import { currentPeriodKey, ensureRentDues, isOverdue, listenRentDues, refreshOverdueDues, type RentDue } from './rent-due-repository';
import { listPaymentsForDue, type RentPayment } from './rent-payment-repository';
import { CollectRentDialog } from './collect-rent-dialog';

function summary(dues: RentDue[]) {
  const month = currentPeriodKey();
  const current = dues.filter(due => due.periodKey === month);
  return {
    expected: current.reduce((sum, due) => sum + due.rentAmountPaise, 0),
    collected: current.reduce((sum, due) => sum + due.totalPaidPaise, 0),
    outstanding: current.reduce((sum, due) => sum + due.balancePaise, 0),
    overdue: dues.filter(isOverdue).reduce((sum, due) => sum + due.balancePaise, 0),
    records: dues.length,
  };
}

export function RentPage({ workspaceId, viewReceipt }: { workspaceId: string; viewReceipt: (paymentId: string) => void }) {
  const [agreements, setAgreements] = useState<Agreement[] | null>(null);
  const [dues, setDues] = useState<RentDue[] | null>(null);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [properties, setProperties] = useState<Property[]>([]);
  const [units, setUnits] = useState<Unit[]>([]);
  const [error, setError] = useState('');
  const [prepared, setPrepared] = useState(false);
  const [search, setSearch] = useState('');
  const [period, setPeriod] = useState('all');
  const [propertyId, setPropertyId] = useState('all');
  const [status, setStatus] = useState('all');
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [collectingId, setCollectingId] = useState<string | null>(null);
  const [collectionNotice, setCollectionNotice] = useState('');
  const [pendingSubmission, setPendingSubmission] = useState<{ dueId: string; submissionId: string; amountPaise: number } | null>(null);
  const [completed, setCompleted] = useState<{ due: RentDue; amountPaise: number; paymentId: string } | null>(null);
  const [canCollect, setCanCollect] = useState(false);
  const generatedSignature = useRef<string | null>(null);
  const refreshed = useRef(new Set<string>());
  const resolutionVersion = useRef(0);

  useEffect(() => {
    const uid = auth.currentUser?.uid;
    if (!uid) { setCanCollect(false); return; }
    return onSnapshot(doc(db, 'workspaceMembers', `${workspaceId}_${uid}`), snapshot => {
      const membership = snapshot.data();
      setCanCollect(membership?.workspaceId === workspaceId && membership.status === 'active' &&
        ['owner', 'manager', 'accountant'].includes(membership.role));
    }, () => setCanCollect(false));
  }, [workspaceId]);

  useEffect(() => {
    generatedSignature.current = null;
    refreshed.current.clear();
    return listenAgreements(workspaceId, setAgreements, () => setError('Rental agreements could not be loaded.'));
  }, [workspaceId]);
  useEffect(() => listenRentDues(workspaceId, setDues, () => setError('Rent dues could not be loaded.')), [workspaceId]);
  useEffect(() => listenTenants(workspaceId, setTenants, () => setError('Tenants could not be loaded.')), [workspaceId]);
  useEffect(() => listenProperties(workspaceId, setProperties, () => setError('Properties could not be loaded.')), [workspaceId]);
  useEffect(() => listenAllUnits(workspaceId, setUnits, () => setError('Units could not be loaded.')), [workspaceId]);
  useEffect(() => {
    if (!agreements) return;
    const signature = agreements.map(item => `${item.id}:${item.status}:${item.startDate}:${item.endDate ?? ''}`).sort().join('|');
    if (signature === generatedSignature.current) return;
    generatedSignature.current = signature;
    setPrepared(false);
    ensureRentDues(workspaceId, agreements).then(() => setPrepared(true)).catch(() => setError('Some rent dues could not be prepared. Please retry.'));
  }, [workspaceId, agreements]);
  useEffect(() => {
    if (!dues) return;
    const pending = dues.filter(due => due.status === 'pending' && isOverdue(due) && !refreshed.current.has(due.id));
    if (!pending.length) return;
    pending.forEach(due => refreshed.current.add(due.id));
    refreshOverdueDues(pending).catch(() => {
      pending.forEach(due => refreshed.current.delete(due.id));
      setError('Overdue status could not be refreshed.');
    });
  }, [dues]);

  const filtered = useMemo(() => (dues ?? []).filter(due => {
    const tenant = tenants.find(item => item.id === due.tenantId);
    const property = properties.find(item => item.id === due.propertyId);
    const unit = units.find(item => item.id === due.unitId);
    return (period === 'all' || due.periodKey === period) &&
      (propertyId === 'all' || due.propertyId === propertyId) &&
      (status === 'all' || due.status === status) &&
      `${tenant?.fullName ?? ''} ${property?.name ?? ''} ${unit?.name ?? ''}`.toLowerCase().includes(search.toLowerCase());
  }), [dues, tenants, properties, units, period, propertyId, status, search]);
  const totals = dues && prepared ? summary(dues) : null;
  const periods = [...new Set((dues ?? []).map(due => due.periodKey))].sort().reverse();
  const selected = dues?.find(due => due.id === selectedId);
  const collecting = dues?.find(due => due.id === collectingId);
  useEffect(() => {
    if (collectingId && collecting && collecting.balancePaise === 0 && !completed) {
      const version = ++resolutionVersion.current;
      setCollectingId(null);
      if (pendingSubmission?.dueId === collectingId) {
        const latestDue = collecting;
        listPaymentsForDue(workspaceId, collectingId).then(payments => {
          if (version !== resolutionVersion.current) return;
          if (payments.some(payment => payment.id === pendingSubmission.submissionId)) {
            setCollectionNotice(''); setCompleted({ due: latestDue, amountPaise: pendingSubmission.amountPaise, paymentId: pendingSubmission.submissionId });
          } else setCollectionNotice('The outstanding balance changed because this due was paid elsewhere. Review Payment History before starting another payment.');
        }).catch(() => { if (version === resolutionVersion.current) setCollectionNotice('This due is now paid. Payment confirmation could not be checked; review Payment History before another payment.'); });
      } else setCollectionNotice('The outstanding balance changed. This due is now paid; review Payment History before starting another payment.');
    }
  }, [collectingId, collecting?.balancePaise, completed, pendingSubmission, workspaceId]);
  return <div className="space-y-6">
    <div><p className="text-sm text-slate-500">Monthly liabilities</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Rent Collection</h1><p className="mt-2 text-sm text-slate-500">Review balances, record payments, and follow collection history across your workspace.</p></div>
    <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
      {[
        ['Current Month Expected', totals?.expected, true],
        ['Current Month Collected', totals?.collected, true],
        ['Current Outstanding', totals?.outstanding, true],
        ['Overdue Outstanding · all periods', totals?.overdue, true],
      ].map(([label, value, money]) => <div key={String(label)} className="rounded-2xl border border-slate-200 bg-white p-5"><p className="text-sm text-slate-500">{label}</p>{value === undefined ? <Skeleton className="mt-3 h-7 w-28" /> : <p className="mt-3 text-2xl font-semibold tabular-nums text-ink">{money ? formatINR(Number(value)) : value}</p>}</div>)}
    </div>
    <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 md:grid-cols-4">
      <input value={search} onChange={event => setSearch(event.target.value)} placeholder="Search tenant or property" aria-label="Search rent dues" className="rounded-xl border border-slate-200 px-3 py-2.5 text-sm" />
      <select value={period} onChange={event => setPeriod(event.target.value)} aria-label="Rent period" className="rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm"><option value="all">All periods</option>{periods.map(item => <option key={item}>{item}</option>)}</select>
      <select value={propertyId} onChange={event => setPropertyId(event.target.value)} aria-label="Property" className="rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm"><option value="all">All properties</option>{properties.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select>
      <select value={status} onChange={event => setStatus(event.target.value)} aria-label="Due status" className="rounded-xl border border-slate-200 bg-white px-3 py-2.5 text-sm"><option value="all">All statuses</option>{['pending', 'partial', 'paid', 'overdue'].map(item => <option key={item} value={item}>{item[0].toUpperCase() + item.slice(1)}</option>)}</select>
    </div>
    {error && <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-4 text-sm text-red-800">{error} <button className="ml-2 font-semibold underline" onClick={() => { generatedSignature.current = null; setError(''); setAgreements(items => items ? [...items] : items); }}>Retry</button></div>}
    {collectionNotice && <div role="alert" className="rounded-xl border border-amber-200 bg-amber-50 p-4 text-sm text-amber-900">{collectionNotice}{pendingSubmission && <button className="ml-2 font-semibold underline" onClick={() => { const latestDue = dues?.find(due => due.id === pendingSubmission.dueId); if (!latestDue) return; listPaymentsForDue(workspaceId, pendingSubmission.dueId).then(payments => { if (payments.some(payment => payment.id === pendingSubmission.submissionId)) { setCompleted({ due: latestDue, amountPaise: pendingSubmission.amountPaise, paymentId: pendingSubmission.submissionId }); setCollectionNotice(''); } else setCollectionNotice('That submission was not recorded. Review the latest balance before trying another payment.'); }).catch(() => setCollectionNotice('Payment status is unavailable. Retry this check when connected.')); }}>Check Payment</button>} <button className="ml-2 font-semibold underline" onClick={() => setCollectionNotice('')}>Dismiss</button></div>}
    {dues === null || !prepared ? <Skeleton className="h-44" /> : filtered.length === 0 ? <EmptyState title="No rent dues in this view" body="Eligible agreement dues will appear here as they are prepared." /> : <SectionCard title={`${filtered.length} Due Records`}><div className="overflow-x-auto"><table className="w-full min-w-[850px] text-left text-sm"><thead className="border-b border-slate-100 text-xs uppercase tracking-wide text-slate-400"><tr>{['Tenant', 'Property / Unit', 'Period', 'Rent', 'Due Date', 'Paid', 'Balance', 'Status', 'Actions'].map(item => <th className="pb-3 pr-3" key={item}>{item}</th>)}</tr></thead><tbody>{filtered.map(due => <tr key={due.id} className="border-b border-slate-100 last:border-0"><td className="py-4 pr-3 font-semibold">{tenants.find(item => item.id === due.tenantId)?.fullName ?? '—'}</td><td className="pr-3">{properties.find(item => item.id === due.propertyId)?.name ?? '—'}<br /><span className="text-xs text-slate-500">{units.find(item => item.id === due.unitId)?.name ?? '—'}</span></td><td className="pr-3">{due.periodKey}</td><td className="pr-3 tabular-nums">{formatINR(due.rentAmountPaise)}</td><td className="pr-3">{formatDate(due.dueDate.toDate())}</td><td className="pr-3 tabular-nums">{formatINR(due.totalPaidPaise)}</td><td className="pr-3 font-semibold tabular-nums">{formatINR(due.balancePaise)}</td><td className="pr-3"><StatusChip status={(due.status[0].toUpperCase() + due.status.slice(1)) as 'Pending'} /></td><td className="space-x-3 whitespace-nowrap"><button className="font-semibold text-brand" onClick={() => setSelectedId(due.id)}>View</button>{canCollect && due.balancePaise > 0 && <button className="font-semibold text-brand" onClick={() => setCollectingId(due.id)}>Collect Rent</button>}</td></tr>)}</tbody></table></div></SectionCard>}
    {selected && <RentDueDetail due={selected} tenant={tenants.find(item => item.id === selected.tenantId)} property={properties.find(item => item.id === selected.propertyId)} unit={units.find(item => item.id === selected.unitId)} agreement={agreements?.find(item => item.id === selected.agreementId)} canCollect={canCollect} collect={() => setCollectingId(selected.id)} close={() => setSelectedId(null)} viewReceipt={viewReceipt} />}
    {collecting && collecting.balancePaise > 0 && <CollectRentDialog key={collecting.id} due={collecting} tenant={tenants.find(item => item.id === collecting.tenantId)} property={properties.find(item => item.id === collecting.propertyId)} unit={units.find(item => collecting.unitId === item.id)} close={() => { setCollectingId(null); setPendingSubmission(null); }} onAttempt={(submissionId, amountPaise) => setPendingSubmission({ dueId: collecting.id, submissionId, amountPaise })} onViewReceipt={viewReceipt} onFullPayment={(latest, amountPaise, paymentId) => { resolutionVersion.current += 1; setCollectionNotice(''); setCompleted({ due: latest, amountPaise, paymentId }); setCollectingId(null); setPendingSubmission(null); }} />}
    {completed && <div className="fixed inset-0 z-[70] grid place-items-center bg-ink/40 p-4"><section role="dialog" aria-modal="true" aria-label="Payment successful" className="w-full max-w-md rounded-3xl bg-white p-7 shadow-soft"><p className="text-xs font-semibold uppercase tracking-[.16em] text-emerald-700">Rent collection</p><h2 className="mt-2 text-2xl font-semibold">Payment recorded successfully</h2><div className="mt-5 grid grid-cols-2 gap-4 rounded-2xl bg-emerald-50 p-5 text-sm"><p>Received<br /><strong>{formatINR(completed.amountPaise)}</strong></p><p>Status<br /><StatusChip status="Paid" /></p><p>Total paid<br /><strong>{formatINR(completed.due.totalPaidPaise)}</strong></p><p>Balance<br /><strong>{formatINR(completed.due.balancePaise)}</strong></p></div><div className="mt-6 flex justify-end gap-2"><Button variant="outline" onClick={() => setCompleted(null)}>Done</Button><Button onClick={() => { const id = completed.paymentId; setCompleted(null); viewReceipt(id); }}>View Receipt</Button></div></section></div>}
  </div>;
}

function RentDueDetail({ due, tenant, property, unit, agreement, canCollect, collect, close, viewReceipt }: { due: RentDue; tenant?: Tenant; property?: Property; unit?: Unit; agreement?: Agreement; canCollect: boolean; collect: () => void; close: () => void; viewReceipt: (paymentId: string) => void }) {
  const [history, setHistory] = useState<RentPayment[] | null>(null);
  const [historyError, setHistoryError] = useState(false);
  useEffect(() => {
    let active = true;
    setHistory(null); setHistoryError(false);
    listPaymentsForDue(due.workspaceId, due.id).then(items => { if (active) setHistory(items); }).catch(() => { if (active) setHistoryError(true); });
    return () => { active = false; };
  }, [due.workspaceId, due.id, due.totalPaidPaise]);
  return <div className="fixed inset-0 z-50 grid place-items-center bg-ink/25 p-4" onClick={close}><section role="dialog" aria-modal="true" aria-label="Rent due detail" onClick={event => event.stopPropagation()} className="max-h-[92vh] w-full max-w-2xl overflow-y-auto rounded-2xl bg-white p-6 shadow-soft"><div className="flex items-start justify-between"><div><p className="text-sm text-slate-500">Rent due · {due.periodKey}</p><h2 className="mt-1 text-2xl font-semibold">{tenant?.fullName ?? 'Tenant'}</h2></div><button onClick={close} aria-label="Close rent due detail" className="text-slate-500">Close</button></div><div className="mt-5 flex items-center gap-3"><StatusChip status={(due.status[0].toUpperCase() + due.status.slice(1)) as 'Pending'} />{isOverdue(due) && due.status === 'partial' && <span className="text-xs font-semibold text-red-700">Past due</span>}</div><dl className="mt-6 grid gap-4 sm:grid-cols-2">{[
    ['Property', property?.name ?? '—'], ['Unit', unit?.name ?? '—'], ['Agreement', agreement ? `${agreement.startDate} · ${agreement.status}` : due.agreementId], ['Rent Period', due.periodKey], ['Rent Amount', formatINR(due.rentAmountPaise)], ['Due Date', formatDate(due.dueDate.toDate())], ['Paid', formatINR(due.totalPaidPaise)], ['Balance', formatINR(due.balancePaise)],
  ].map(([label, value]) => <div key={label}><dt className="text-xs uppercase tracking-wide text-slate-400">{label}</dt><dd className="mt-1 font-semibold text-ink">{value}</dd></div>)}</dl>
  <div className="mt-7 border-t border-slate-100 pt-5"><h3 className="font-semibold text-ink">Payment History</h3>{historyError ? <p role="alert" className="mt-3 text-sm text-red-700">Payment history could not be loaded. Reopen this due to retry.</p> : history === null ? <Skeleton className="mt-3 h-20" /> : history.length === 0 ? <EmptyState title="No payments yet" body="Recorded payments will appear here in date order." /> : <div className="mt-3 space-y-2">{history.map(payment => <div key={payment.id} className="grid gap-1 rounded-xl border border-slate-100 px-4 py-3 text-sm sm:grid-cols-[1fr_1fr_1fr_1fr]"><span>{formatDate(payment.paymentDate.toDate())}</span><strong className="tabular-nums">{formatINR(payment.amountPaise)}</strong><span className="capitalize">{payment.paymentMode.replace('_', ' ')}</span><span className="text-slate-500">{payment.referenceNumber || '—'}{payment.createdBy && <span className="block truncate text-xs" title={payment.createdBy}>By {payment.createdBy}</span>}</span><button className="text-left font-semibold text-brand" onClick={() => { close(); viewReceipt(payment.id); }}>View Receipt</button>{payment.notes && <span className="sm:col-span-4 text-xs text-slate-500">{payment.notes}</span>}</div>)}</div>}</div>
  <div className="mt-7 flex justify-end gap-3"><Button variant="outline" onClick={close}>Done</Button>{canCollect && due.balancePaise > 0 && <Button onClick={collect}>Collect Rent</Button>}</div></section></div>;
}
