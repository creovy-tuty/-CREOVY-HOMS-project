import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { Button, EmptyState, Skeleton, StatusChip, TextInput, ToastNotice } from '../../design/components';
import { formatDate, formatINR } from '../../design/tokens';
import { listenAllUnits, listenProperties, type Property, type Unit } from '../properties/property-repository';
import { createBill, getBill, getBillPayment, isPropertyBillLate, listenBillPayments, listenBills, listBills,
  newBillPaymentSubmissionId, recordBillPayment, refreshOverdueState, updateSafeBillMetadata,
  type BillDraft, type PropertyBill, type PropertyBillPayment, type SafeBillMetadata, type BillPaymentSubmission } from './property-bill-repository';
import type { PropertyBillPaymentMode, PropertyBillType } from '@creovy/contracts';

const billTypes: { value: PropertyBillType; label: string }[] = [
  { value: 'electricity', label: 'Electricity / EB' }, { value: 'water_tax', label: 'Water Tax' },
  { value: 'property_tax', label: 'Property Tax' }, { value: 'other', label: 'Other Bill' },
];
const modes: { value: PropertyBillPaymentMode; label: string }[] = [
  { value: 'cash', label: 'Cash' }, { value: 'upi', label: 'UPI' }, { value: 'bank_transfer', label: 'Bank Transfer' },
  { value: 'cheque', label: 'Cheque' }, { value: 'other', label: 'Other' },
];
const typeName = (type: PropertyBillType) => billTypes.find(item => item.value === type)?.label ?? type;
const modeName = (mode: PropertyBillPaymentMode) => modes.find(item => item.value === mode)?.label ?? mode;
const amountText = (paise: number) => `${Math.floor(paise / 100)}${paise % 100 ? `.${String(paise % 100).padStart(2, '0')}` : ''}`;
function parsePaise(text: string): number | null {
  if (!/^\d+(?:\.\d{1,2})?$/.test(text)) return null;
  const [whole, minor = ''] = text.split('.');
  const value = BigInt(whole) * 100n + BigInt(minor.padEnd(2, '0'));
  return value > 0n && value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : null;
}
function parseIndiaDate(text: string): Date | null {
  const match = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(text.trim());
  if (!match) return null;
  const day = Number(match[1]), month = Number(match[2]), year = Number(match[3]);
  const calendar = new Date(Date.UTC(year, month - 1, day));
  if (calendar.getUTCFullYear() !== year || calendar.getUTCMonth() !== month - 1 || calendar.getUTCDate() !== day) return null;
  return new Date(calendar.getTime() - 19800000);
}
const todayIndia = () => formatDate(new Date());
const statusName = (bill: PropertyBill) => bill.status === 'pending' && isPropertyBillLate(bill) ? 'Overdue' :
  (bill.status.slice(0, 1).toUpperCase() + bill.status.slice(1)) as 'Pending' | 'Partial' | 'Paid' | 'Overdue';
const selectClass = 'w-full rounded-xl border border-slate-200 bg-white px-4 py-3 text-sm text-ink outline-none focus:border-brand';

function Overlay({ title, close, children, busy = false }: { title: string; close: () => void; children: ReactNode; busy?: boolean }) {
  return <div className="fixed inset-0 z-50 grid place-items-center bg-ink/40 p-3 sm:p-6" onMouseDown={busy ? undefined : close}>
    <section role="dialog" aria-modal="true" aria-label={title} onMouseDown={event => event.stopPropagation()} className="max-h-[94vh] w-full max-w-2xl overflow-y-auto rounded-3xl bg-white p-5 shadow-soft sm:p-7">
      <div className="mb-5 flex items-center justify-between gap-4"><h2 className="text-xl font-semibold text-ink">{title}</h2><button type="button" onClick={close} disabled={busy} className="rounded-lg px-3 py-2 text-sm text-slate-500 hover:bg-slate-100">Close</button></div>{children}
    </section>
  </div>;
}

export function BillsPage({ workspaceId, role, initialPropertyId }: { workspaceId: string; role: string; initialPropertyId?: string | null }) {
  const canWrite = role === 'owner' || role === 'manager' || role === 'accountant';
  const [properties, setProperties] = useState<Property[] | null>(null);
  const [units, setUnits] = useState<Unit[] | null>(null);
  const [bills, setBills] = useState<PropertyBill[] | null>(null);
  const [error, setError] = useState('');
  const [notice, setNotice] = useState('');
  const [search, setSearch] = useState('');
  const [typeFilter, setTypeFilter] = useState('all');
  const [propertyFilter, setPropertyFilter] = useState(initialPropertyId ?? 'all');
  const [statusFilter, setStatusFilter] = useState('all');
  const [editor, setEditor] = useState<'add' | 'edit' | null>(null);
  const [selected, setSelected] = useState<PropertyBill | null>(null);
  const [paying, setPaying] = useState(false);
  const load = useCallback(async () => {
    try {
      const items = await listBills(workspaceId);
      setBills(items); setError('');
      if (canWrite) {
        const stale = items.filter(item => item.status === 'pending' && isPropertyBillLate(item));
        if (stale.length) {
          await Promise.all(stale.map(item => refreshOverdueState(workspaceId, item.id)));
          setBills(await listBills(workspaceId));
        }
      }
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Unable to load bills.'); }
  }, [workspaceId, canWrite]);
  useEffect(() => { void load(); }, [load]);
  useEffect(() => listenBills(workspaceId, items => { setBills(items); setError(''); }, cause => setError(cause.message)), [workspaceId]);
  useEffect(() => listenProperties(workspaceId, setProperties, cause => setError(cause.message)), [workspaceId]);
  useEffect(() => listenAllUnits(workspaceId, setUnits, cause => setError(cause.message)), [workspaceId]);
  useEffect(() => { setPropertyFilter(initialPropertyId ?? 'all'); }, [initialPropertyId]);
  const latestSelected = bills?.find(item => item.id === selected?.id) ?? selected;
  const refreshSelected = async () => { await load(); if (selected) setSelected(await getBill(workspaceId, selected.id)); };
  const filtered = (bills ?? []).filter(bill => {
    const property = properties?.find(item => item.id === bill.propertyId)?.name ?? '';
    const unit = units?.find(item => item.id === bill.unitId)?.name ?? '';
    const haystack = `${typeName(bill.billType)} ${property} ${unit} ${bill.providerName} ${bill.consumerNumber} ${bill.periodKey}`.toLowerCase();
    return haystack.includes(search.toLowerCase()) && (typeFilter === 'all' || bill.billType === typeFilter) &&
      (propertyFilter === 'all' || bill.propertyId === propertyFilter) &&
      (statusFilter === 'all' || statusName(bill).toLowerCase() === statusFilter);
  });
  const metrics = { count: bills?.length ?? 0, pending: 0, paid: 0, overdue: 0 };
  for (const bill of bills ?? []) {
    metrics.paid += bill.totalPaidPaise;
    if (isPropertyBillLate(bill)) metrics.overdue += bill.balancePaise;
    else metrics.pending += bill.balancePaise;
  }
  const propertyName = (id: string) => properties?.find(item => item.id === id)?.name ?? 'Property';
  const unitName = (id: string | null) => id ? units?.find(item => item.id === id)?.name ?? 'Unit' : 'Property level';
  return <div className="space-y-5">
    <div className="flex flex-wrap items-end justify-between gap-4"><div><p className="text-sm font-medium text-slate-500">Finance / Manual tracking</p><h1 className="mt-1 text-3xl font-semibold tracking-tight text-ink">Bills & Taxes</h1><p className="mt-1 text-sm text-slate-500">Electricity, water, property tax and other property bills in one place.</p></div>{canWrite && <Button onClick={() => setEditor('add')}>Add Bill</Button>}</div>
    <div className="grid grid-cols-2 gap-3 xl:grid-cols-4">{[['Total Bills', String(metrics.count)], ['Pending Amount', formatINR(metrics.pending)], ['Paid Amount', formatINR(metrics.paid)], ['Overdue Amount', formatINR(metrics.overdue)]].map(([label, value]) => <div key={label} className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-medium text-slate-500">{label}</p>{bills === null ? <Skeleton className="mt-3 h-6 w-24" /> : <p className="mt-2 text-xl font-semibold tabular-nums text-ink">{value}</p>}</div>)}</div>
    <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 xl:grid-cols-[minmax(12rem,1fr)_repeat(3,minmax(9rem,12rem))]"><input aria-label="Search bills" value={search} onChange={event => setSearch(event.target.value)} placeholder="Search provider, property, reference…" className={selectClass} /><select aria-label="Bill type" value={typeFilter} onChange={event => setTypeFilter(event.target.value)} className={selectClass}><option value="all">All bill types</option>{billTypes.map(item => <option value={item.value} key={item.value}>{item.label}</option>)}</select><select aria-label="Property" value={propertyFilter} onChange={event => setPropertyFilter(event.target.value)} className={selectClass}><option value="all">All properties</option>{properties?.map(item => <option value={item.id} key={item.id}>{item.name}</option>)}</select><select aria-label="Status" value={statusFilter} onChange={event => setStatusFilter(event.target.value)} className={selectClass}><option value="all">All statuses</option>{['pending', 'partial', 'paid', 'overdue'].map(item => <option value={item} key={item}>{item[0].toUpperCase() + item.slice(1)}</option>)}</select></div>
    {error && <ToastNotice tone="danger" message={error} />}
    {notice && <ToastNotice tone="success" message={notice} />}
    {bills === null || properties === null || units === null ? <div className="space-y-3"><Skeleton className="h-16" /><Skeleton className="h-16" /><Skeleton className="h-16" /></div> : error ? <EmptyState title="Bills could not be loaded" body="Check your connection and try again." action={<Button variant="outline" onClick={() => void load()}>Retry</Button>} /> : filtered.length === 0 ? <EmptyState title={bills.length ? 'No bills match these filters' : 'No bills yet'} body={bills.length ? 'Try another search or filter.' : 'Add your first bill to track payment status and due dates.'} action={canWrite && !bills.length ? <Button onClick={() => setEditor('add')}>Add Bill</Button> : undefined} /> : <>
      <div className="hidden overflow-x-auto rounded-2xl border border-slate-200 bg-white xl:block"><table className="w-full min-w-[1180px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr>{['Bill', 'Property / Unit', 'Provider / Reference', 'Period', 'Due', 'Amount', 'Paid', 'Balance', 'Status', ''].map(item => <th key={item} className="px-4 py-3 font-semibold">{item}</th>)}</tr></thead><tbody>{filtered.map(bill => <tr key={bill.id} className="border-t border-slate-100"><td className="px-4 py-4 font-semibold">{typeName(bill.billType)}</td><td className="px-4 py-4">{propertyName(bill.propertyId)}<p className="text-xs text-slate-500">{unitName(bill.unitId)}</p></td><td className="px-4 py-4">{bill.providerName}<p className="text-xs text-slate-500">{bill.consumerNumber || 'No reference'}</p></td><td className="px-4 py-4">{bill.periodKey || '—'}</td><td className="px-4 py-4 tabular-nums">{formatDate(bill.dueDate.toDate())}</td><td className="px-4 py-4 tabular-nums">{formatINR(bill.amountPaise)}</td><td className="px-4 py-4 tabular-nums">{formatINR(bill.totalPaidPaise)}</td><td className="px-4 py-4 font-semibold tabular-nums">{formatINR(bill.balancePaise)}</td><td className="px-4 py-4"><StatusChip status={statusName(bill)} />{bill.status === 'partial' && isPropertyBillLate(bill) && <p className="mt-1 text-xs font-semibold text-red-700">Past due</p>}</td><td className="px-4 py-4"><button onClick={() => setSelected(bill)} className="font-semibold text-brand hover:underline">View</button></td></tr>)}</tbody></table></div>
      <div className="grid gap-3 sm:grid-cols-2 xl:hidden">{filtered.map(bill => <button key={bill.id} onClick={() => setSelected(bill)} className="rounded-2xl border border-slate-200 bg-white p-4 text-left transition hover:border-brand"><div className="flex items-start justify-between gap-3"><div><p className="font-semibold">{typeName(bill.billType)}</p><p className="mt-1 text-sm text-slate-500">{propertyName(bill.propertyId)} · {unitName(bill.unitId)}</p></div><StatusChip status={statusName(bill)} /></div><p className="mt-3 text-sm">{bill.providerName} · {bill.consumerNumber || bill.periodKey || 'No reference'}</p><p className="mt-2 text-xs text-slate-500">Period {bill.periodKey || '—'} · Bill {formatINR(bill.amountPaise)} · Paid {formatINR(bill.totalPaidPaise)}</p><div className="mt-4 flex justify-between border-t border-slate-100 pt-3 text-sm"><span className="text-slate-500">Due {formatDate(bill.dueDate.toDate())}</span><strong>{formatINR(bill.balancePaise)} balance</strong></div>{bill.status === 'partial' && isPropertyBillLate(bill) && <p className="mt-2 text-xs font-semibold text-red-700">Past due</p>}</button>)}</div>
    </>}
    {latestSelected && <BillDetail bill={latestSelected} propertyName={propertyName(latestSelected.propertyId)} unitName={unitName(latestSelected.unitId)} canWrite={canWrite} close={() => setSelected(null)} edit={() => setEditor('edit')} pay={() => setPaying(true)} refresh={refreshSelected} />}
    {editor && <BillEditor mode={editor} bill={editor === 'edit' ? latestSelected : null} workspaceId={workspaceId} properties={properties ?? []} units={units ?? []} initialPropertyId={propertyFilter !== 'all' ? propertyFilter : undefined} close={() => setEditor(null)} saved={async () => { setNotice(editor === 'add' ? 'Bill added successfully.' : 'Bill details updated.'); setEditor(null); await refreshSelected(); }} />}
    {paying && latestSelected && <BillPaymentDialog key={latestSelected.id} bill={latestSelected} propertyName={propertyName(latestSelected.propertyId)} unitName={unitName(latestSelected.unitId)} close={() => setPaying(false)} saved={refreshSelected} />}
  </div>;
}

function BillEditor({ mode, bill, workspaceId, properties, units, initialPropertyId, close, saved }: { mode: 'add' | 'edit'; bill: PropertyBill | null; workspaceId: string; properties: Property[]; units: Unit[]; initialPropertyId?: string; close: () => void; saved: () => Promise<void> }) {
  const [type, setType] = useState<PropertyBillType>(bill?.billType ?? 'electricity');
  const [propertyId, setPropertyId] = useState(bill?.propertyId ?? initialPropertyId ?? '');
  const [unitId, setUnitId] = useState(bill?.unitId ?? '');
  const [provider, setProvider] = useState(bill?.providerName ?? '');
  const [consumer, setConsumer] = useState(bill?.consumerNumber ?? '');
  const [period, setPeriod] = useState(bill?.periodKey ?? '');
  const [billDate, setBillDate] = useState(bill ? formatDate(bill.billDate.toDate()) : todayIndia());
  const [dueDate, setDueDate] = useState(bill ? formatDate(bill.dueDate.toDate()) : todayIndia());
  const [amount, setAmount] = useState(bill ? amountText(bill.amountPaise) : '');
  const [notes, setNotes] = useState(bill?.notes ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const paid = !!bill && bill.totalPaidPaise > 0;
  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const billInstant = parseIndiaDate(billDate), dueInstant = parseIndiaDate(dueDate), paise = parsePaise(amount);
    if (!propertyId || !provider.trim() || !billInstant || !dueInstant || !paise || dueInstant < billInstant) { setError('Check property, provider, dates (DD/MM/YYYY), and a positive amount.'); return; }
    setBusy(true); setError('');
    try {
      if (mode === 'add') {
        const draft: BillDraft = { workspaceId, propertyId, unitId: unitId || null, billType: type, providerName: provider, consumerNumber: consumer, periodKey: period, billDate: billInstant, dueDate: dueInstant, amountPaise: paise, notes };
        await createBill(draft);
      } else if (bill) {
        const changes: SafeBillMetadata = paid ? { notes } : { providerName: provider, consumerNumber: consumer, periodKey: period, billDate: billInstant, dueDate: dueInstant, amountPaise: paise, notes };
        await updateSafeBillMetadata(workspaceId, bill.id, changes);
      }
      await saved();
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Bill could not be saved.'); }
    finally { setBusy(false); }
  };
  return <Overlay title={mode === 'add' ? 'Add bill' : 'Edit safe details'} close={close} busy={busy}><form onSubmit={submit} className="space-y-4">
    {paid && <ToastNotice message="This bill has payment history. Only notes can be changed." />}
    <div className="grid gap-4 sm:grid-cols-2"><label className="block text-sm font-medium">Bill type<select disabled={mode === 'edit'} value={type} onChange={event => setType(event.target.value as PropertyBillType)} className={`mt-2 ${selectClass}`}>{billTypes.map(item => <option value={item.value} key={item.value}>{item.label}</option>)}</select></label><label className="block text-sm font-medium">Property *<select disabled={mode === 'edit'} value={propertyId} onChange={event => { setPropertyId(event.target.value); setUnitId(''); }} className={`mt-2 ${selectClass}`}><option value="">Select property</option>{properties.map(item => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label></div>
    <label className="block text-sm font-medium">Unit (optional)<select disabled={mode === 'edit'} value={unitId} onChange={event => setUnitId(event.target.value)} className={`mt-2 ${selectClass}`}><option value="">Property level</option>{units.filter(item => item.propertyId === propertyId).map(item => <option value={item.id} key={item.id}>{item.name}</option>)}</select></label>
    <div className="grid gap-4 sm:grid-cols-2"><TextInput label="Provider / authority *" value={provider} disabled={paid} onChange={event => setProvider(event.target.value)} /><TextInput label="Consumer / assessment number" value={consumer} disabled={paid} onChange={event => setConsumer(event.target.value)} /><TextInput label="Billing period" value={period} disabled={paid} onChange={event => setPeriod(event.target.value)} placeholder="e.g. 2026-09" /><TextInput label="Amount (₹) *" inputMode="decimal" value={amount} disabled={paid} onChange={event => setAmount(event.target.value)} /><TextInput label="Bill date (DD/MM/YYYY) *" value={billDate} disabled={paid} onChange={event => setBillDate(event.target.value)} placeholder="DD/MM/YYYY" /><TextInput label="Due date (DD/MM/YYYY) *" value={dueDate} disabled={paid} onChange={event => setDueDate(event.target.value)} placeholder="DD/MM/YYYY" /></div>
    <label className="block text-sm font-medium">Notes<textarea value={notes} onChange={event => setNotes(event.target.value)} rows={3} className={`mt-2 ${selectClass}`} /></label>
    {error && <ToastNotice tone="danger" message={error} />}<div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={close} disabled={busy}>Cancel</Button><Button loading={busy}>{mode === 'add' ? 'Add Bill' : 'Save Details'}</Button></div>
  </form></Overlay>;
}

function BillDetail({ bill, propertyName, unitName, canWrite, close, edit, pay, refresh }: { bill: PropertyBill; propertyName: string; unitName: string; canWrite: boolean; close: () => void; edit: () => void; pay: () => void; refresh: () => Promise<void> }) {
  const [history, setHistory] = useState<PropertyBillPayment[] | null>(null);
  const [error, setError] = useState('');
  useEffect(() => { setHistory(null); return listenBillPayments(bill.workspaceId, bill.id, setHistory, cause => setError(cause.message)); }, [bill.workspaceId, bill.id]);
  return <Overlay title="Bill detail" close={close}><div className="space-y-5"><div className="flex flex-wrap items-center justify-between gap-3"><div><p className="text-xs font-semibold uppercase tracking-widest text-brand">{typeName(bill.billType)}</p><h3 className="mt-1 text-xl font-semibold">{bill.providerName}</h3><p className="mt-1 text-sm text-slate-500">{propertyName} · {unitName}</p></div><div className="text-right"><StatusChip status={statusName(bill)} />{bill.status === 'partial' && isPropertyBillLate(bill) && <p className="mt-1 text-xs font-semibold text-red-700">Past due</p>}</div></div>
    <div className="grid grid-cols-2 gap-3 rounded-2xl bg-slate-50 p-4 text-sm sm:grid-cols-3">{[['Consumer / assessment', bill.consumerNumber || '—'], ['Billing period', bill.periodKey || '—'], ['Bill date', formatDate(bill.billDate.toDate())], ['Due date', formatDate(bill.dueDate.toDate())], ['Original amount', formatINR(bill.amountPaise)], ['Total paid', formatINR(bill.totalPaidPaise)]].map(([label, value]) => <p key={label}><span className="text-xs text-slate-500">{label}</span><br /><strong className="tabular-nums">{value}</strong></p>)}</div>
    <div className="flex items-center justify-between rounded-2xl border border-violet-100 bg-violet-50 p-4"><span className="text-sm text-slate-600">Remaining balance</span><strong className="text-xl tabular-nums text-brand">{formatINR(bill.balancePaise)}</strong></div>{bill.notes && <p className="text-sm text-slate-600"><strong className="text-ink">Notes</strong><br />{bill.notes}</p>}
    {canWrite && <div className="flex flex-wrap gap-2"><Button disabled={bill.balancePaise === 0} onClick={pay}>Record Payment</Button><Button variant="outline" onClick={edit}>Edit Safe Details</Button></div>}
    <div className="border-t border-slate-100 pt-5"><div className="mb-3 flex items-center justify-between"><h4 className="font-semibold">Payment history</h4><button className="text-sm font-semibold text-brand" onClick={() => { void refresh(); }}>Refresh</button></div>{error && <ToastNotice tone="danger" message={error} />}{history === null ? <Skeleton className="h-20" /> : history.length === 0 ? <EmptyState title="No payments recorded" body="Payments will appear here after they are confirmed." /> : <div className="space-y-2">{history.map(payment => <div key={payment.id} className="rounded-xl border border-slate-100 p-3 text-sm"><div className="flex justify-between gap-3"><strong>{formatINR(payment.amountPaise)}</strong><span className="tabular-nums text-slate-500">{formatDate(payment.paymentDate.toDate())}</span></div><p className="mt-1 text-slate-600">{modeName(payment.paymentMode)}{payment.referenceNumber ? ` · ${payment.referenceNumber}` : ''}</p>{payment.notes && <p className="mt-1 text-slate-500">{payment.notes}</p>}<p className="mt-1 text-xs text-slate-400">Recorded by {payment.createdBy}</p></div>)}</div>}</div>
  </div></Overlay>;
}

function BillPaymentDialog({ bill, propertyName, unitName, close, saved }: { bill: PropertyBill; propertyName: string; unitName: string; close: () => void; saved: () => Promise<void> }) {
  const [current, setCurrent] = useState(bill);
  const [amount, setAmount] = useState(amountText(bill.balancePaise));
  const [date, setDate] = useState(todayIndia());
  const [mode, setMode] = useState<PropertyBillPaymentMode>('upi');
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [stage, setStage] = useState<'edit' | 'confirm' | 'success'>('edit');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [success, setSuccess] = useState<PropertyBill | null>(null);
  const [paid, setPaid] = useState(0);
  const submissionId = useRef(newBillPaymentSubmissionId());
  const attempted = useRef(false);
  const inFlight = useRef(false);
  const reviewedBalance = useRef(bill.balancePaise);
  const parsed = parsePaise(amount);
  const paymentInstant = parseIndiaDate(date);
  const valid = parsed !== null && parsed <= current.balancePaise && paymentInstant !== null;
  const change = (update: () => void) => { if (attempted.current) { submissionId.current = newBillPaymentSubmissionId(); attempted.current = false; } update(); setStage('edit'); setError(''); };
  const review = async () => {
    if (!valid) return;
    setBusy(true); setError('');
    try {
      const latest = await getBill(bill.workspaceId, bill.id);
      if (!latest) throw new Error('Bill is no longer available.');
      setCurrent(latest);
      if (latest.balancePaise !== current.balancePaise || parsed! > latest.balancePaise) { setError('Balance changed on another device. Review the latest balance and amount again.'); return; }
      reviewedBalance.current = latest.balancePaise; setStage('confirm');
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Unable to refresh the bill.'); }
    finally { setBusy(false); }
  };
  const submit = async () => {
    if (inFlight.current || !parsed || !paymentInstant) return;
    inFlight.current = true; setBusy(true); setError('');
    try {
      const existing = attempted.current ? await getBillPayment(bill.workspaceId, submissionId.current) : null;
      if (!existing) {
        const latest = await getBill(bill.workspaceId, bill.id);
        if (!latest) throw new Error('Bill is no longer available.');
        if (latest.balancePaise !== reviewedBalance.current || parsed > latest.balancePaise) {
          setCurrent(latest); setStage('edit'); setError('Balance changed on another device. Review the latest balance and amount again.'); return;
        }
      }
      const input: BillPaymentSubmission = { workspaceId: bill.workspaceId, billId: bill.id, submissionId: submissionId.current,
        amountPaise: parsed, paymentDate: paymentInstant, paymentMode: mode, referenceNumber: reference, notes };
      attempted.current = true;
      await recordBillPayment(input);
      const latest = await getBill(bill.workspaceId, bill.id);
      if (!latest) throw new Error('Payment recorded, but bill reload failed. Retry with the same submission ID.');
      setSuccess(latest); setPaid(parsed); setStage('success');
      await saved().catch(() => setError('Payment recorded, but the list could not refresh. Reopen the bill to retry loading.'));
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : 'Payment status is uncertain.';
      if (/exceeds the outstanding balance|totals or status are inconsistent/.test(message)) { setStage('edit'); setError('Balance changed. Review the latest bill and amount before trying again.'); const latest = await getBill(bill.workspaceId, bill.id).catch(() => null); if (latest) setCurrent(latest); }
      else setError(`${message} Retry with the same submission ID if uncertain.`);
    } finally { inFlight.current = false; setBusy(false); }
  };
  return <Overlay title={stage === 'success' ? 'Payment Recorded' : stage === 'confirm' ? 'Confirm Bill Payment' : 'Record Bill Payment'} close={close} busy={busy}><div className="space-y-5"><div className="rounded-2xl bg-slate-50 p-4 text-sm"><p className="font-semibold">{typeName(current.billType)} · {current.providerName}</p><p className="mt-1 text-slate-500">{propertyName} · {unitName}</p><p className="mt-3">Current balance <strong>{formatINR((success ?? current).balancePaise)}</strong></p></div>
    {stage === 'edit' && <><TextInput label="Amount paying (₹)" value={amount} inputMode="decimal" onChange={event => change(() => setAmount(event.target.value))} error={amount && !valid ? 'Enter a positive amount no greater than the latest balance.' : undefined} /><button onClick={() => change(() => setAmount(amountText(current.balancePaise)))} className="text-sm font-semibold text-brand">Use full balance</button><div className="grid gap-4 sm:grid-cols-2"><TextInput label="Payment date (DD/MM/YYYY)" value={date} onChange={event => change(() => setDate(event.target.value))} /><label className="block text-sm font-medium">Payment mode<select value={mode} onChange={event => change(() => setMode(event.target.value as PropertyBillPaymentMode))} className={`mt-2 ${selectClass}`}>{modes.map(item => <option value={item.value} key={item.value}>{item.label}</option>)}</select></label></div><TextInput label="Reference number" value={reference} onChange={event => change(() => setReference(event.target.value))} /><label className="block text-sm font-medium">Notes<textarea value={notes} onChange={event => change(() => setNotes(event.target.value))} rows={2} className={`mt-2 ${selectClass}`} /></label><div className="flex justify-between rounded-xl border border-violet-100 bg-violet-50 p-4 text-sm"><span>Balance after payment</span><strong>{valid ? formatINR(current.balancePaise - parsed!) : '—'}</strong></div>{error && <ToastNotice tone="danger" message={error} />}<div className="flex justify-end"><Button disabled={!valid} loading={busy} onClick={() => void review()}>Review Payment</Button></div></>}
    {stage === 'confirm' && <><div className="space-y-3 rounded-2xl border border-slate-200 p-4 text-sm">{[['Bill', `${typeName(current.billType)} · ${current.providerName}`], ['Property / Unit', `${propertyName} · ${unitName}`], ['Amount paying', formatINR(parsed ?? 0)], ['Current balance', formatINR(reviewedBalance.current)], ['Balance after payment', formatINR(reviewedBalance.current - (parsed ?? 0))], ['Payment mode', modeName(mode)], ['Payment date', date]].map(([label, value]) => <div className="flex justify-between gap-4" key={label}><span className="text-slate-500">{label}</span><strong className="text-right">{value}</strong></div>)}</div>{error && <ToastNotice tone="danger" message={error} />}<div className="flex justify-end gap-2"><Button variant="outline" disabled={busy} onClick={() => setStage('edit')}>Back</Button><Button loading={busy} onClick={() => void submit()}>{attempted.current ? 'Retry Same Payment' : 'Confirm Payment'}</Button></div></>}
    {stage === 'success' && success && <><ToastNotice tone="success" message={`Payment Recorded · ${formatINR(paid)}`} /><div className="grid grid-cols-2 gap-3 rounded-2xl border border-emerald-100 bg-emerald-50 p-4 text-sm"><p>Total paid<br /><strong>{formatINR(success.totalPaidPaise)}</strong></p><p>Remaining balance<br /><strong>{formatINR(success.balancePaise)}</strong></p><div><StatusChip status={statusName(success)} /></div></div>{error && <ToastNotice tone="danger" message={error} />}<div className="flex justify-end gap-2"><Button variant="outline" onClick={close}>Done</Button><Button onClick={close}>View Bill</Button></div></>}
  </div></Overlay>;
}
