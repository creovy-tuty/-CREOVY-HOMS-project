import { useEffect, useRef, useState } from 'react';
import { Button, StatusChip, TextInput } from '../../design/components';
import { formatDate, formatINR } from '../../design/tokens';
import type { Property, Unit } from '../properties/property-repository';
import type { Tenant } from '../tenants/tenant-repository';
import { getRentDue, type RentDue } from './rent-due-repository';
import { newPaymentSubmissionId, recordPayment, type PaymentMode } from './rent-payment-repository';

const modes: { value: PaymentMode; label: string }[] = [
  { value: 'cash', label: 'Cash' }, { value: 'upi', label: 'UPI' },
  { value: 'bank_transfer', label: 'Bank Transfer' }, { value: 'cheque', label: 'Cheque' },
  { value: 'other', label: 'Other' },
];
const todayIndia = () => { const parts = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date()); const value = (type: string) => parts.find(part => part.type === type)?.value ?? ''; return `${value('year')}-${value('month')}-${value('day')}`; };
const amountText = (paise: number) => { const amount = BigInt(paise); const minor = amount % 100n; return `${amount / 100n}${minor === 0n ? '' : `.${minor.toString().padStart(2, '0')}`}`; };
function parsePaise(value: string): number | null {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value)) return null;
  const [rupees, fraction = ''] = value.split('.');
  const amount = BigInt(rupees) * 100n + BigInt(fraction.padEnd(2, '0'));
  return amount <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(amount) : null;
}

export function CollectRentDialog({ due, tenant, property, unit, close, onFullPayment, onAttempt, onViewReceipt }: { due: RentDue; tenant?: Tenant; property?: Property; unit?: Unit; close: () => void; onFullPayment: (latest: RentDue, amountPaise: number, paymentId: string) => void; onAttempt: (submissionId: string, amountPaise: number) => void; onViewReceipt: (paymentId: string) => void }) {
  const [initialSubmissionId] = useState(newPaymentSubmissionId);
  const submissionId = useRef(initialSubmissionId);
  const attempted = useRef(false);
  const inFlight = useRef(false);
  const [amount, setAmount] = useState(amountText(due.balancePaise));
  const [date, setDate] = useState(todayIndia());
  const [mode, setMode] = useState<PaymentMode>('upi');
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [stage, setStage] = useState<'edit' | 'confirm' | 'success'>('edit');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState('');
  const [successDue, setSuccessDue] = useState<RentDue | null>(null);
  const reviewedBalance = useRef(due.balancePaise);
  const parsed = parsePaise(amount);
  const valid = parsed !== null && parsed > 0 && parsed <= due.balancePaise && /^\d{4}-\d{2}-\d{2}$/.test(date);
  const after = valid && parsed !== null ? due.balancePaise - parsed : null;

  useEffect(() => {
    if (stage === 'confirm' && !attempted.current && due.balancePaise !== reviewedBalance.current) {
      setStage('edit');
      setError('The outstanding balance changed. Please review the updated amount.');
    }
  }, [due.balancePaise, stage]);

  function changeIntent(update: () => void) {
    if (attempted.current) { submissionId.current = newPaymentSubmissionId(); attempted.current = false; }
    setError(''); update();
  }

  async function submit() {
    if (inFlight.current || parsed === null || parsed <= 0 || (!attempted.current && (!valid || reviewedBalance.current !== due.balancePaise))) {
      setStage('edit'); setError('The outstanding balance changed. Please review the updated amount.'); return;
    }
    inFlight.current = true; setSubmitting(true); setError(''); attempted.current = true;
    onAttempt(submissionId.current, parsed);
    try {
      await recordPayment({ workspaceId: due.workspaceId, rentDueId: due.id, submissionId: submissionId.current,
        amountPaise: parsed, paymentDate: new Date(`${date}T00:00:00+05:30`), paymentMode: mode,
        referenceNumber: reference, notes });
      const latest = await getRentDue(due.workspaceId, due.id);
      if (!latest) throw new Error('Payment was recorded, but the latest due could not be loaded. Retry safely with the same submission ID.');
      if (latest.balancePaise === 0) onFullPayment(latest, parsed, submissionId.current);
      else { setSuccessDue(latest); setStage('success'); }
    } catch (cause) {
      const message = cause instanceof Error ? cause.message : 'Payment could not be recorded. Please retry with the same submission.';
      if (/exceeds the outstanding balance|already fully paid|totals are inconsistent|status is inconsistent/.test(message)) {
        setStage('edit'); setError('The outstanding balance changed. Please review the updated amount.');
      } else {
        try { await getRentDue(due.workspaceId, due.id); } catch { /* The same UUID remains safe to retry. */ }
        setError(`${message} Retry with the same submission ID if the result is uncertain.`);
      }
    } finally { inFlight.current = false; setSubmitting(false); }
  }

  return <div className="fixed inset-0 z-[60] grid place-items-center bg-ink/40 p-3 sm:p-6" onClick={submitting ? undefined : close}>
    <section role="dialog" aria-modal="true" aria-label="Collect rent" onClick={event => event.stopPropagation()} className="max-h-[92vh] w-full max-w-2xl overflow-y-auto rounded-3xl bg-white p-5 shadow-soft sm:p-7">
      <div className="flex items-start justify-between"><div><p className="text-xs font-semibold uppercase tracking-[.16em] text-brand">Rent collection</p><h2 className="mt-1 text-2xl font-semibold text-ink">{stage === 'success' ? 'Payment recorded successfully' : stage === 'confirm' ? 'Confirm payment' : 'Collect Rent'}</h2></div><button onClick={close} disabled={submitting} aria-label="Close" className="rounded-lg px-2 py-1 text-sm text-slate-500 hover:bg-slate-100">Close</button></div>
      <div className="mt-5 grid gap-3 rounded-2xl bg-slate-50 p-4 text-sm sm:grid-cols-2">
        <p><span className="text-slate-500">Tenant</span><br /><strong>{tenant?.fullName ?? '—'}</strong></p><p><span className="text-slate-500">Property · Unit</span><br /><strong>{property?.name ?? '—'} · {unit?.name ?? '—'}</strong></p>
        <p><span className="text-slate-500">Rent period</span><br /><strong>{due.periodKey}</strong></p><p><span className="text-slate-500">Rent amount</span><br /><strong>{formatINR(due.rentAmountPaise)}</strong></p>
        <p><span className="text-slate-500">Already paid</span><br /><strong>{formatINR((successDue ?? due).totalPaidPaise)}</strong></p><p><span className="text-slate-500">Current balance</span><br /><strong>{formatINR((successDue ?? due).balancePaise)}</strong></p>
      </div>
      {stage === 'edit' && <div className="mt-6 space-y-4">
        <div className="grid gap-3 sm:grid-cols-[1fr_auto] sm:items-end"><TextInput label="Receiving now (₹)" inputMode="decimal" value={amount} onChange={event => changeIntent(() => setAmount(event.target.value))} error={amount && !valid ? 'Enter an amount above ₹0 and no more than the current balance.' : undefined} /><Button variant="outline" onClick={() => { const full = amountText(due.balancePaise); if (full !== amount) changeIntent(() => setAmount(full)); }}>Pay Full Balance</Button></div>
        <div className="grid gap-4 sm:grid-cols-2"><TextInput label="Payment date" type="date" value={date} onChange={event => changeIntent(() => setDate(event.target.value))} /><label className="block"><span className="mb-2 block text-sm font-medium text-slate-700">Payment mode</span><select value={mode} onChange={event => changeIntent(() => setMode(event.target.value as PaymentMode))} className="w-full rounded-xl border border-slate-200 bg-white px-4 py-3">{modes.map(item => <option key={item.value} value={item.value}>{item.label}</option>)}</select></label></div>
        <TextInput label="Reference number (optional)" value={reference} onChange={event => changeIntent(() => setReference(event.target.value))} /><label className="block text-sm font-medium text-slate-700">Notes (optional)<textarea value={notes} onChange={event => changeIntent(() => setNotes(event.target.value))} rows={2} className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3" /></label>
        <div className="flex items-center justify-between rounded-xl border border-violet-100 bg-violet-50 p-4"><span className="text-sm text-slate-600">Balance after payment</span><strong className="tabular-nums text-brand">{after === null ? '—' : formatINR(after)}</strong></div>
        {error && <p role="alert" className="rounded-xl bg-red-50 p-3 text-sm text-red-800">{error}</p>}
        <div className="flex justify-end"><Button disabled={!valid} onClick={() => { reviewedBalance.current = due.balancePaise; setStage('confirm'); setError(''); }}>Review Payment</Button></div>
      </div>}
      {stage === 'confirm' && <div className="mt-6 space-y-4"><div className="space-y-3 rounded-2xl border border-slate-200 p-5 text-sm">{[['Receiving now', formatINR(parsed ?? 0)], ['Payment mode', modes.find(item => item.value === mode)?.label ?? mode], ['Payment date', formatDate(new Date(`${date}T00:00:00+05:30`))], ['Balance after payment', formatINR(reviewedBalance.current - (parsed ?? 0))]].map(([label, value]) => <div key={label} className="flex justify-between gap-3"><span className="text-slate-500">{label}</span><strong className="text-right">{value}</strong></div>)}</div>{error && <p role="alert" className="rounded-xl bg-red-50 p-3 text-sm text-red-800">{error}</p>}<div className="flex justify-end gap-3"><Button variant="outline" disabled={submitting} onClick={() => setStage('edit')}>Back</Button><Button loading={submitting} onClick={submit}>{attempted.current ? 'Retry Same Payment' : 'Confirm Payment'}</Button></div></div>}
      {stage === 'success' && successDue && <div className="mt-6 space-y-4"><div className="rounded-2xl border border-emerald-100 bg-emerald-50 p-5"><p className="text-sm font-semibold text-emerald-800">Received {formatINR(parsed ?? 0)}</p><div className="mt-4 grid grid-cols-2 gap-4 text-sm"><p>Total paid<br /><strong>{formatINR(successDue.totalPaidPaise)}</strong></p><p>Balance<br /><strong>{formatINR(successDue.balancePaise)}</strong></p></div><div className="mt-4"><StatusChip status={successDue.status === 'paid' ? 'Paid' : 'Partial'} /></div></div><div className="flex justify-end gap-2"><Button variant="outline" onClick={close}>Done</Button><Button onClick={() => { const id = submissionId.current; close(); onViewReceipt(id); }}>View Receipt</Button></div></div>}
    </section>
  </div>;
}
