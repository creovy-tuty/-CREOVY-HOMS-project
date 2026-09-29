import { useCallback, useEffect, useRef, useState, type FormEvent, type ReactNode } from 'react';
import type { PropertyExpenseCategory, PropertyExpensePaymentMode } from '@creovy/contracts';
import { Button, EmptyState, Skeleton, TextInput, ToastNotice } from '../../design/components';
import { formatDate, formatINR } from '../../design/tokens';
import { listenAllUnits, listenProperties, type Property, type Unit } from '../properties/property-repository';
import { createExpense, getExpense, listExpenses, newExpenseSubmissionId, updateSafeExpenseMetadata,
  type ExpenseSubmission, type PropertyExpense } from './property-expense-repository';

const categories: { value: PropertyExpenseCategory; label: string }[] = [
  { value: 'maintenance', label: 'Maintenance' }, { value: 'repair', label: 'Repair' },
  { value: 'plumbing', label: 'Plumbing' }, { value: 'electrical', label: 'Electrical' },
  { value: 'cleaning', label: 'Cleaning' }, { value: 'painting', label: 'Painting' },
  { value: 'security', label: 'Security' }, { value: 'labour', label: 'Service / Labour' },
  { value: 'common_area', label: 'Common Area' }, { value: 'other', label: 'Other' },
];
const modes: { value: PropertyExpensePaymentMode; label: string }[] = [
  { value: 'cash', label: 'Cash' }, { value: 'upi', label: 'UPI' },
  { value: 'bank_transfer', label: 'Bank Transfer' }, { value: 'cheque', label: 'Cheque' },
  { value: 'other', label: 'Other' },
];
const categoryName = (value: string) => categories.find(item => item.value === value)?.label ?? value;
const modeName = (value: string) => modes.find(item => item.value === value)?.label ?? value;
const selectClass = 'w-full rounded-xl border border-slate-200 bg-white px-3 py-3 text-sm text-ink outline-none focus:border-brand';
const indiaParts = (date: Date) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' }).format(date);
const todayIndia = () => indiaParts(new Date());
const createdAtIndia = (date: Date) => `${formatDate(date)} ${new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }).format(date)} IST`;
function parseDate(value: string): Date | null {
  const match = /^(\d{2})\/(\d{2})\/(\d{4})$/.exec(value.trim());
  if (!match) return null;
  const day = Number(match[1]), month = Number(match[2]), year = Number(match[3]);
  const date = new Date(Date.UTC(year, month - 1, day));
  return date.getUTCFullYear() === year && date.getUTCMonth() === month - 1 && date.getUTCDate() === day ?
    new Date(date.getTime() - 19800000) : null;
}
function parsePaise(value: string): number | null {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value.trim())) return null;
  const [whole, minor = ''] = value.trim().split('.');
  const paise = BigInt(whole) * 100n + BigInt(minor.padEnd(2, '0'));
  return paise > 0n && paise <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(paise) : null;
}
function Dialog({ title, close, busy, children }: { title: string; close: () => void; busy?: boolean; children: ReactNode }) {
  return <div className="fixed inset-0 z-50 grid place-items-center bg-ink/40 p-3 sm:p-6" onMouseDown={busy ? undefined : close}>
    <section role="dialog" aria-modal="true" aria-label={title} onMouseDown={event => event.stopPropagation()} className="max-h-[94vh] w-full max-w-2xl overflow-y-auto rounded-3xl bg-white p-5 shadow-soft sm:p-7">
      <div className="mb-5 flex items-center justify-between gap-4"><h2 className="text-xl font-semibold">{title}</h2><button type="button" onClick={close} disabled={busy} className="rounded-lg px-3 py-2 text-sm text-slate-500 hover:bg-slate-100">Close</button></div>{children}
    </section>
  </div>;
}

export function ExpensesPage({ workspaceId, role, initialPropertyId, initialUnitId, openAddRequest = 0 }: { workspaceId: string; role: string; initialPropertyId?: string | null; initialUnitId?: string | null; openAddRequest?: number }) {
  const canWrite = ['owner', 'manager', 'accountant'].includes(role);
  const [properties, setProperties] = useState<Property[] | null>(null);
  const [units, setUnits] = useState<Unit[] | null>(null);
  const [expenses, setExpenses] = useState<PropertyExpense[] | null>(null);
  const [expenseError, setExpenseError] = useState('');
  const [propertyError, setPropertyError] = useState('');
  const [unitError, setUnitError] = useState('');
  const [retryContext, setRetryContext] = useState(0);
  const [notice, setNotice] = useState('');
  const [search, setSearch] = useState('');
  const [propertyId, setPropertyId] = useState(initialPropertyId ?? 'all');
  const [unitId, setUnitId] = useState(initialUnitId ?? 'all');
  const [category, setCategory] = useState('all');
  const [paymentMode, setPaymentMode] = useState('all');
  const [from, setFrom] = useState('');
  const [through, setThrough] = useState('');
  const [adding, setAdding] = useState(false);
  const [selected, setSelected] = useState<PropertyExpense | null>(null);
  const [editing, setEditing] = useState(false);
  const refresh = useCallback(async () => {
    try { setExpenses(await listExpenses(workspaceId)); setExpenseError(''); }
    catch (cause) { setExpenseError(cause instanceof Error ? cause.message : 'Unable to load expenses.'); }
  }, [workspaceId]);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => listenProperties(workspaceId, items => { setProperties(items); setPropertyError(''); }, cause => setPropertyError(cause.message)), [workspaceId, retryContext]);
  useEffect(() => listenAllUnits(workspaceId, items => { setUnits(items); setUnitError(''); }, cause => setUnitError(cause.message)), [workspaceId, retryContext]);
  useEffect(() => { setPropertyId(initialPropertyId ?? 'all'); setUnitId(initialUnitId ?? 'all'); }, [initialPropertyId, initialUnitId]);
  useEffect(() => { if (openAddRequest > 0 && canWrite) setAdding(true); }, [openAddRequest, canWrite]);
  const propertyName = (id: string) => properties?.find(item => item.id === id)?.name ?? 'Property';
  const unitName = (id: string | null) => id ? units?.find(item => item.id === id)?.name ?? 'Unit' : 'Property level';
  const error = expenseError || propertyError || unitError;
  const retry = () => { setProperties(null); setUnits(null); setPropertyError(''); setUnitError(''); setRetryContext(value => value + 1); void refresh(); };
  const fromDate = from ? parseDate(from) : null, throughDate = through ? parseDate(through) : null;
  const dateError = from && !fromDate || through && !throughDate || fromDate && throughDate && fromDate > throughDate;
  const filtered = (expenses ?? []).filter(item => {
    const day = item.expenseDate.toMillis();
    const context = `${item.title} ${item.vendorName} ${item.referenceNumber} ${propertyName(item.propertyId)} ${unitName(item.unitId)}`.toLowerCase();
    return context.includes(search.trim().toLowerCase()) && (propertyId === 'all' || item.propertyId === propertyId) &&
      (unitId === 'all' || item.unitId === unitId) && (category === 'all' || item.category === category) &&
      (paymentMode === 'all' || item.paymentMode === paymentMode) && (!fromDate || day >= fromDate.getTime()) &&
      (!throughDate || day <= throughDate.getTime());
  });
  const total = (expenses ?? []).reduce((sum, item) => sum + item.amountPaise, 0);
  const month = todayIndia().slice(3);
  const thisMonth = (expenses ?? []).filter(item => indiaParts(item.expenseDate.toDate()).slice(3) === month)
    .reduce((sum, item) => sum + item.amountPaise, 0);
  const byCategory = new Map<string, number>();
  for (const item of expenses ?? []) byCategory.set(item.category, (byCategory.get(item.category) ?? 0) + item.amountPaise);
  const top = [...byCategory.entries()].sort((a, b) => b[1] - a[1])[0];
  const clear = () => { setSearch(''); setPropertyId('all'); setUnitId('all'); setCategory('all'); setPaymentMode('all'); setFrom(''); setThrough(''); };
  const hasFilters = !!(search || propertyId !== 'all' || unitId !== 'all' || category !== 'all' || paymentMode !== 'all' || from || through);
  return <div className="space-y-5">
    <div className="flex flex-wrap items-end justify-between gap-4"><div><p className="text-sm font-medium text-slate-500">Finance / Owner outflows</p><h1 className="mt-1 text-3xl font-semibold tracking-tight">Expenses</h1><p className="mt-1 text-sm text-slate-500">A clear record of what it costs to run your properties.</p></div><div className="flex gap-2"><Button variant="outline" onClick={retry}>Refresh</Button>{canWrite && <Button onClick={() => setAdding(true)}>Add Expense</Button>}</div></div>
    <div className="grid grid-cols-2 gap-3 xl:grid-cols-4">{[['Total Expenses', formatINR(total)], ['This Month', formatINR(thisMonth)], ['Transactions', String(expenses?.length ?? 0)], ['Top Category', top ? categoryName(top[0]) : '—']].map(([label, value]) => <div key={label} className="rounded-2xl border border-slate-200 bg-white p-4"><p className="text-xs font-medium text-slate-500">{label}</p>{expenses === null ? <Skeleton className="mt-3 h-6 w-24" /> : <p className="mt-2 text-xl font-semibold tabular-nums">{value}</p>}</div>)}</div>
    <div className="grid gap-3 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-2 xl:grid-cols-[minmax(12rem,1fr)_repeat(6,minmax(8rem,10rem))]"><input aria-label="Search expenses" value={search} onChange={event => setSearch(event.target.value)} placeholder="Search title, vendor, reference…" className={selectClass} /><input aria-label="From date DD/MM/YYYY" value={from} onChange={event => setFrom(event.target.value)} placeholder="From DD/MM/YYYY" className={selectClass} /><input aria-label="Through date DD/MM/YYYY" value={through} onChange={event => setThrough(event.target.value)} placeholder="To DD/MM/YYYY" className={selectClass} /><select aria-label="Property" value={propertyId} onChange={event => { setPropertyId(event.target.value); setUnitId('all'); }} className={selectClass}><option value="all">All properties</option>{properties?.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select><select aria-label="Unit" value={unitId} onChange={event => setUnitId(event.target.value)} className={selectClass}><option value="all">All units</option>{units?.filter(item => propertyId === 'all' || item.propertyId === propertyId).map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select><select aria-label="Category" value={category} onChange={event => setCategory(event.target.value)} className={selectClass}><option value="all">All categories</option>{categories.map(item => <option key={item.value} value={item.value}>{item.label}</option>)}</select><select aria-label="Payment mode" value={paymentMode} onChange={event => setPaymentMode(event.target.value)} className={selectClass}><option value="all">All modes</option>{modes.map(item => <option key={item.value} value={item.value}>{item.label}</option>)}</select></div>
    {dateError && <ToastNotice tone="danger" message="Enter valid DD/MM/YYYY dates, with the start no later than the end." />}{error && <ToastNotice tone="danger" message={error} />}{notice && <ToastNotice tone="success" message={notice} />}
    {error ? <EmptyState title="Expenses unavailable" body="Check your connection and try again." action={<Button variant="outline" onClick={retry}>Retry</Button>} /> : expenses === null || properties === null || units === null ? <div className="space-y-3"><Skeleton className="h-16" /><Skeleton className="h-16" /><Skeleton className="h-16" /></div> : filtered.length === 0 ? <EmptyState title={expenses.length ? 'No expenses match these filters' : 'No expenses recorded yet'} body={expenses.length ? 'Try a different search or filter.' : 'Record your first owner expense to begin a reliable history.'} action={hasFilters ? <Button variant="outline" onClick={clear}>Clear Filters</Button> : canWrite ? <Button onClick={() => setAdding(true)}>Add Expense</Button> : undefined} /> : <>
      <div className="hidden overflow-x-auto rounded-2xl border border-slate-200 bg-white xl:block"><table className="w-full min-w-[1100px] text-left text-sm"><thead className="bg-slate-50 text-xs uppercase tracking-wide text-slate-500"><tr>{['Date', 'Category / Title', 'Property / Unit', 'Vendor', 'Amount', 'Mode / Reference', ''].map(item => <th key={item} className="px-4 py-3 font-semibold">{item}</th>)}</tr></thead><tbody>{filtered.map(item => <tr key={item.id} className="border-t border-slate-100"><td className="px-4 py-4 tabular-nums">{formatDate(item.expenseDate.toDate())}</td><td className="px-4 py-4"><span className="text-xs text-slate-500">{categoryName(item.category)}</span><p className="font-semibold">{item.title}</p></td><td className="px-4 py-4">{propertyName(item.propertyId)}<p className="text-xs text-slate-500">{unitName(item.unitId)}</p></td><td className="px-4 py-4">{item.vendorName || '—'}</td><td className="px-4 py-4 font-semibold tabular-nums">{formatINR(item.amountPaise)}</td><td className="px-4 py-4">{modeName(item.paymentMode)}<p className="text-xs text-slate-500">{item.referenceNumber || '—'}</p></td><td className="px-4 py-4"><button onClick={() => setSelected(item)} className="font-semibold text-brand hover:underline">View</button></td></tr>)}</tbody></table></div>
      <div className="grid gap-3 sm:grid-cols-2 xl:hidden">{filtered.map(item => <button key={item.id} onClick={() => setSelected(item)} className="rounded-2xl border border-slate-200 bg-white p-4 text-left transition hover:border-brand"><div className="flex justify-between gap-3"><div><p className="text-xs font-semibold uppercase tracking-wide text-brand">{categoryName(item.category)}</p><h3 className="mt-1 font-semibold">{item.title}</h3></div><strong className="tabular-nums">{formatINR(item.amountPaise)}</strong></div><p className="mt-2 text-sm text-slate-500">{propertyName(item.propertyId)} · {unitName(item.unitId)}</p><p className="mt-3 border-t border-slate-100 pt-3 text-xs text-slate-500">{formatDate(item.expenseDate.toDate())} · {modeName(item.paymentMode)} · {item.vendorName || 'No vendor'}{item.referenceNumber ? ` · ${item.referenceNumber}` : ''}</p></button>)}</div>
    </>}
    {adding && <ExpenseEditor workspaceId={workspaceId} properties={properties ?? []} units={units ?? []} initialPropertyId={propertyId === 'all' ? undefined : propertyId} close={() => setAdding(false)} recorded={async (item, view) => { setNotice('Expense Recorded'); await refresh(); setAdding(false); if (view) setSelected(item); }} />}
    {selected && <Dialog title="Expense Detail" close={() => setSelected(null)}><div className="space-y-5"><div className="flex justify-between gap-4"><div><p className="text-xs font-semibold uppercase tracking-widest text-brand">{categoryName(selected.category)}</p><h3 className="mt-1 text-xl font-semibold">{selected.title}</h3><p className="mt-1 text-sm text-slate-500">{propertyName(selected.propertyId)} · {unitName(selected.unitId)}</p></div><strong className="text-xl tabular-nums">{formatINR(selected.amountPaise)}</strong></div><div className="grid grid-cols-2 gap-4 rounded-2xl bg-slate-50 p-4 text-sm">{[['Expense Date', formatDate(selected.expenseDate.toDate())], ['Vendor', selected.vendorName || '—'], ['Payment Mode', modeName(selected.paymentMode)], ['Reference', selected.referenceNumber || '—'], ['Recorded By', selected.createdBy], ['Created At', selected.createdAt ? createdAtIndia(selected.createdAt.toDate()) : '—']].map(([label, value]) => <p key={label}><span className="text-xs text-slate-500">{label}</span><br /><strong>{value}</strong></p>)}</div><p className="text-sm text-slate-600"><strong className="text-ink">Notes</strong><br />{selected.notes || 'No notes'}</p>{canWrite && <Button variant="outline" onClick={() => setEditing(true)}>Edit Safe Details</Button>}</div></Dialog>}
    {selected && editing && <SafeEdit expense={selected} close={() => setEditing(false)} saved={async () => { const updated = await getExpense(workspaceId, selected.id); if (updated) setSelected(updated); setEditing(false); setNotice('Expense details updated.'); await refresh(); }} />}
  </div>;
}

function ExpenseEditor({ workspaceId, properties, units, initialPropertyId, close, recorded }: { workspaceId: string; properties: Property[]; units: Unit[]; initialPropertyId?: string; close: () => void; recorded: (item: PropertyExpense, view: boolean) => Promise<void> }) {
  const [propertyId, setPropertyId] = useState(initialPropertyId ?? '');
  const [unitId, setUnitId] = useState('');
  const [category, setCategory] = useState<PropertyExpenseCategory>('maintenance');
  const [title, setTitle] = useState('');
  const [vendorName, setVendorName] = useState('');
  const [amount, setAmount] = useState('');
  const [expenseDate, setExpenseDate] = useState(todayIndia());
  const [paymentMode, setPaymentMode] = useState<PropertyExpensePaymentMode>('cash');
  const [referenceNumber, setReferenceNumber] = useState('');
  const [notes, setNotes] = useState('');
  const [stage, setStage] = useState<'form' | 'review' | 'success'>('form');
  const [result, setResult] = useState<PropertyExpense | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const submissionId = useRef(newExpenseSubmissionId());
  const attempted = useRef(false);
  const inFlight = useRef(false);
  const propertyName = properties.find(item => item.id === propertyId)?.name ?? 'Property';
  const unitName = units.find(item => item.id === unitId)?.name ?? 'Property level';
  const change = (update: () => void, financial = false) => {
    if (attempted.current && financial) { submissionId.current = newExpenseSubmissionId(); attempted.current = false; }
    update(); setStage('form'); setError('');
  };
  const review = (event: FormEvent) => {
    event.preventDefault();
    if (!propertyId || unitId && !units.some(item => item.id === unitId && item.propertyId === propertyId) ||
        !title.trim() || title.trim().length > 200 || vendorName.trim().length > 200 ||
        referenceNumber.trim().length > 200 || notes.trim().length > 2000 || !parsePaise(amount) || !parseDate(expenseDate)) {
      setError('Check property, unit, title, positive amount, date (DD/MM/YYYY), and field lengths.'); return;
    }
    setError(''); setStage('review');
  };
  const submit = async () => {
    if (inFlight.current || !parsePaise(amount) || !parseDate(expenseDate)) return;
    inFlight.current = true; setBusy(true); setError('');
    try {
      const input: ExpenseSubmission = { workspaceId, submissionId: submissionId.current, propertyId,
        unitId: unitId || null, category, title, vendorName, amountPaise: parsePaise(amount)!,
        expenseDate: parseDate(expenseDate)!, paymentMode, referenceNumber, notes };
      attempted.current = true;
      const item = await createExpense(input);
      setResult(item); setStage('success');
    } catch (cause) { setError(`${cause instanceof Error ? cause.message : 'Expense status is uncertain.'} Retry with the same submission ID if uncertain.`); }
    finally { inFlight.current = false; setBusy(false); }
  };
  return <Dialog title={stage === 'success' ? 'Expense Recorded' : stage === 'review' ? 'Review Expense' : 'Add Expense'} close={() => { if (result) void recorded(result, false); else close(); }} busy={busy}><div className="space-y-5">
    {stage === 'form' && <form onSubmit={review} className="space-y-4"><div className="grid gap-4 sm:grid-cols-2"><label className="text-sm font-medium">Property *<select value={propertyId} onChange={event => change(() => { setPropertyId(event.target.value); setUnitId(''); }, true)} className={`mt-2 ${selectClass}`}><option value="">Select property</option>{properties.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><label className="text-sm font-medium">Unit (optional)<select value={unitId} onChange={event => change(() => setUnitId(event.target.value), true)} className={`mt-2 ${selectClass}`}><option value="">Property level</option>{units.filter(item => item.propertyId === propertyId).map(item => <option key={item.id} value={item.id}>{item.name}</option>)}</select></label><label className="text-sm font-medium">Category<select value={category} onChange={event => change(() => setCategory(event.target.value as PropertyExpenseCategory), true)} className={`mt-2 ${selectClass}`}>{categories.map(item => <option key={item.value} value={item.value}>{item.label}</option>)}</select></label><TextInput label="Title *" value={title} onChange={event => change(() => setTitle(event.target.value))} /><TextInput label="Vendor Name" value={vendorName} onChange={event => change(() => setVendorName(event.target.value))} /><TextInput label="Amount (₹) *" inputMode="decimal" value={amount} onChange={event => change(() => setAmount(event.target.value), true)} /><TextInput label="Expense Date (DD/MM/YYYY) *" value={expenseDate} onChange={event => change(() => setExpenseDate(event.target.value), true)} /><label className="text-sm font-medium">Payment Mode<select value={paymentMode} onChange={event => change(() => setPaymentMode(event.target.value), true)} className={`mt-2 ${selectClass}`}>{modes.map(item => <option key={item.value} value={item.value}>{item.label}</option>)}</select></label><TextInput label="Reference Number" value={referenceNumber} onChange={event => change(() => setReferenceNumber(event.target.value), true)} /></div><label className="block text-sm font-medium">Notes<textarea value={notes} onChange={event => change(() => setNotes(event.target.value))} rows={3} className={`mt-2 ${selectClass}`} /></label>{error && <ToastNotice tone="danger" message={error} />}<div className="flex justify-end gap-2"><Button type="button" variant="outline" onClick={close}>Cancel</Button><Button>Review Expense</Button></div></form>}
    {stage === 'review' && <><p className="text-sm text-slate-500">No expense is recorded until you confirm.</p><div className="space-y-3 rounded-2xl border border-slate-200 p-4 text-sm">{[['Property', propertyName], ['Unit', unitName], ['Category', categoryName(category)], ['Title', title.trim()], ['Vendor', vendorName.trim() || '—'], ['Amount', formatINR(parsePaise(amount) ?? 0)], ['Expense Date', expenseDate], ['Payment Mode', modeName(paymentMode)], ['Reference', referenceNumber.trim() || '—']].map(([label, value]) => <div className="flex justify-between gap-4" key={label}><span className="text-slate-500">{label}</span><strong className="text-right">{value}</strong></div>)}</div>{error && <ToastNotice tone="danger" message={error} />}<div className="flex justify-end gap-2"><Button variant="outline" disabled={busy} onClick={() => setStage('form')}>Back</Button><Button loading={busy} onClick={() => void submit()}>{attempted.current ? 'Retry Same Expense' : 'Confirm Expense'}</Button></div></>}
    {stage === 'success' && result && <><div className="rounded-2xl border border-emerald-100 bg-emerald-50 p-5"><p className="font-semibold text-emerald-800">Expense Recorded</p><p className="mt-2 text-2xl font-semibold tabular-nums">{formatINR(result.amountPaise)}</p><p className="mt-1 text-sm text-slate-600">{propertyName} · {unitName}</p><p className="mt-2 text-sm text-slate-600">{categoryName(result.category)} · {formatDate(result.expenseDate.toDate())}</p></div><div className="flex justify-end gap-2"><Button variant="outline" onClick={() => void recorded(result, false)}>Done</Button><Button onClick={() => void recorded(result, true)}>View Expense</Button></div></>}
  </div></Dialog>;
}

function SafeEdit({ expense, close, saved }: { expense: PropertyExpense; close: () => void; saved: () => Promise<void> }) {
  const [title, setTitle] = useState(expense.title), [vendorName, setVendorName] = useState(expense.vendorName), [notes, setNotes] = useState(expense.notes);
  const [confirm, setConfirm] = useState(false), [busy, setBusy] = useState(false), [error, setError] = useState('');
  const submit = async () => {
    setBusy(true); setError('');
    try { await updateSafeExpenseMetadata(expense.workspaceId, expense.id, { title, vendorName, notes }); await saved(); }
    catch (cause) { setError(cause instanceof Error ? cause.message : 'Details could not be updated.'); }
    finally { setBusy(false); }
  };
  return <Dialog title="Edit Safe Details" close={close} busy={busy}><div className="space-y-4"><p className="text-sm text-slate-500">Amount, property, date and payment identity remain locked.</p>{!confirm ? <><TextInput label="Title" value={title} onChange={event => setTitle(event.target.value)} /><TextInput label="Vendor Name" value={vendorName} onChange={event => setVendorName(event.target.value)} /><label className="block text-sm font-medium">Notes<textarea rows={3} value={notes} onChange={event => setNotes(event.target.value)} className={`mt-2 ${selectClass}`} /></label><div className="flex justify-end"><Button disabled={!title.trim()} onClick={() => setConfirm(true)}>Review Changes</Button></div></> : <><div className="rounded-2xl bg-slate-50 p-4 text-sm"><p><strong>{title.trim()}</strong></p><p className="mt-2">Vendor: {vendorName.trim() || '—'}</p><p className="mt-2">Notes: {notes.trim() || '—'}</p></div><div className="flex justify-end gap-2"><Button variant="outline" disabled={busy} onClick={() => setConfirm(false)}>Back</Button><Button loading={busy} onClick={() => void submit()}>Save Changes</Button></div></>}{error && <ToastNotice tone="danger" message={error} />}</div></Dialog>;
}
