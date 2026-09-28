import { useEffect, useState } from 'react';
import { Button, EmptyState, SectionCard, Skeleton, ToastNotice } from '../../design/components';
import { formatINR } from '../../design/tokens';
import { listenAgreements, listenTenants, type Agreement, type Tenant } from './tenant-repository';
import { listenAllUnits, listenProperties, type Property, type Unit } from '../properties/property-repository';
import { getDepositSummary, listenDepositSummary, listenDepositTransactions, newDepositSubmissionId, recordDepositReceived, recordDepositRefund, type DepositPaymentMode, type DepositSubmission, type DepositSummary, type DepositTransaction, type DepositTransactionType } from './security-deposit-repository';
import { listenDepositLedger, type DepositLedgerEntry } from './security-deposit-financial-repository';
import { DepositReceiptDetail } from './deposit-receipt-detail';

const financialRole = (role: string) => ['owner', 'manager', 'accountant'].includes(role);
const moneyInput = (paise: number) => (paise / 100).toFixed(2);
const parsePaise = (value: string) => {
  const clean = value.trim();
  if (!/^\d+(?:\.\d{1,2})?$/.test(clean)) return null;
  const [whole, fraction = ''] = clean.split('.');
  const paise = Number(whole) * 100 + Number(fraction.padEnd(2, '0'));
  return Number.isSafeInteger(paise) ? paise : null;
};
const displayDate = (date: Date) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' }).format(date);
const todayInKolkata = () => {
  const parts = new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
  const value = (part: string) => parts.find(item => item.type === part)?.value ?? '';
  return `${value('year')}-${value('month')}-${value('day')}`;
};
const sameBalance = (a: DepositSummary, b: DepositSummary) => a.agreedAmountPaise === b.agreedAmountPaise && a.totalReceivedPaise === b.totalReceivedPaise && a.pendingToReceivePaise === b.pendingToReceivePaise && a.totalRefundedPaise === b.totalRefundedPaise && a.heldBalancePaise === b.heldBalancePaise && a.lastTransactionId === b.lastTransactionId;

function Metric({ label, amount }: { label: string; amount: number }) { return <div className="rounded-xl border border-slate-200 bg-slate-50/60 p-3"><p className="text-xs font-medium text-slate-500">{label}</p><p className="mt-1 text-lg font-semibold tabular-nums text-ink">{formatINR(amount)}</p></div>; }

function MovementForm({ workspaceId, agreement, summary, type, tenantName, propertyName, unitName, close, completed }: { workspaceId: string; agreement: Agreement; summary: DepositSummary; type: DepositTransactionType; tenantName: string; propertyName: string; unitName: string; close: () => void; completed: (movement: DepositTransaction, latest: DepositSummary) => void }) {
  const [amount, setAmount] = useState(moneyInput(type === 'received' ? summary.pendingToReceivePaise : summary.heldBalancePaise));
  const [date, setDate] = useState(todayInKolkata());
  const [mode, setMode] = useState<DepositPaymentMode>('upi');
  const [reference, setReference] = useState('');
  const [notes, setNotes] = useState('');
  const [submissionId] = useState(newDepositSubmissionId);
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [review, setReview] = useState<DepositSummary>(summary);
  const [attempted, setAttempted] = useState<DepositSubmission | null>(null);
  useEffect(() => { if (!attempted && !sameBalance(review, summary)) setError('The live deposit balance changed. Review the updated totals before confirming.'); }, [summary, attempted, review]);
  const limit = type === 'received' ? review.pendingToReceivePaise : review.heldBalancePaise;
  const paise = parsePaise(amount);
  const valid = paise !== null && paise > 0 && paise <= limit && !!date;
  const title = type === 'received' ? 'Receive deposit' : 'Refund deposit';
  const submit = async (retry = false) => {
    if (busy) return;
    setBusy(true); setError('');
    try {
      const input = retry ? attempted : valid ? {
        workspaceId, agreementId: agreement.id, submissionId, amountPaise: paise!,
        transactionDate: new Date(`${date}T00:00:00+05:30`), paymentMode: mode,
        referenceNumber: reference, notes,
      } : null;
      if (!input) throw new Error('Enter a positive amount within the available balance.');
      if (!retry) {
        const latest = await getDepositSummary(workspaceId, agreement.id);
        if (!sameBalance(review, latest)) {
          setReview(latest); setConfirm(false);
          setError('The deposit balance changed on another device. Review the new totals and amount, then confirm again.');
          return;
        }
        setAttempted(input);
      }
      const movement = type === 'received' ? await recordDepositReceived(input) : await recordDepositRefund(input);
      const latest = await getDepositSummary(workspaceId, agreement.id);
      window.dispatchEvent(new CustomEvent('creovy:deposit-recorded', { detail: { agreementId: agreement.id, transactionId: movement.id } }));
      completed(movement, latest);
    } catch (cause) {
      setError(`${cause instanceof Error ? cause.message : 'The outcome is uncertain.'} ${attempted || retry ? 'Retry this same submission ID; do not submit a new movement.' : ''}`);
    } finally { setBusy(false); }
  };
  return <div className="fixed inset-0 z-[60] flex items-center justify-center overflow-y-auto bg-ink/35 p-3 sm:p-6"><section role="dialog" aria-modal="true" aria-label={title} className="w-full max-w-xl rounded-3xl bg-white p-5 shadow-soft sm:p-7"><div className="flex items-start justify-between"><div><p className="text-xs font-bold uppercase tracking-[.14em] text-brand">Security deposit</p><h2 className="mt-1 text-2xl font-semibold">{title}</h2><p className="mt-1 text-sm text-slate-500">{tenantName} · {propertyName} / {unitName}</p></div><button disabled={busy} onClick={close} className="rounded-lg px-2 py-1 text-slate-500 hover:bg-slate-100" aria-label="Close">✕</button></div><div className="mt-5 grid grid-cols-2 gap-2 sm:grid-cols-4"><Metric label="Agreed" amount={review.agreedAmountPaise} /><Metric label="Received" amount={review.totalReceivedPaise} /><Metric label={type === 'received' ? 'Pending' : 'Refunded'} amount={type === 'received' ? review.pendingToReceivePaise : review.totalRefundedPaise} /><Metric label="Held" amount={review.heldBalancePaise} /></div>{error && <div className="mt-4"><ToastNotice message={error} tone="danger" /></div>}{attempted && error ? <div className="mt-5 flex justify-end gap-2"><Button variant="outline" onClick={close}>Close</Button><Button loading={busy} onClick={() => submit(true)}>Retry same submission</Button></div> : <><div className="mt-5 grid gap-4 sm:grid-cols-2"><label className="text-sm font-medium text-slate-700">Amount (₹)<input disabled={busy || confirm} inputMode="decimal" value={amount} onChange={event => setAmount(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3" /></label><label className="text-sm font-medium text-slate-700">{type === 'received' ? 'Transaction' : 'Refund'} date<input disabled={busy || confirm} type="date" value={date} onChange={event => setDate(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3" /></label><label className="text-sm font-medium text-slate-700">Payment mode<select disabled={busy || confirm} value={mode} onChange={event => setMode(event.target.value as DepositPaymentMode)} className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3"><option value="upi">UPI</option><option value="cash">Cash</option><option value="bank_transfer">Bank transfer</option><option value="cheque">Cheque</option><option value="other">Other</option></select></label><label className="text-sm font-medium text-slate-700">Reference number<input disabled={busy || confirm} value={reference} maxLength={200} onChange={event => setReference(event.target.value)} className="mt-2 w-full rounded-xl border border-slate-200 px-4 py-3" /></label></div><label className="mt-4 block text-sm font-medium text-slate-700">Notes<textarea disabled={busy || confirm} value={notes} maxLength={2000} onChange={event => setNotes(event.target.value)} className="mt-2 min-h-20 w-full rounded-xl border border-slate-200 px-4 py-3" /></label>{paise !== null && paise > limit && <p className="mt-2 text-sm text-red-700">Amount exceeds {type === 'received' ? 'pending deposit' : 'the held balance'}.</p>}{confirm && valid && <div className="mt-4 rounded-xl border border-violet-200 bg-violet-50 p-4 text-sm"><p className="font-semibold">Confirm {type === 'received' ? 'collection' : 'refund'} of {formatINR(paise!)}</p><p className="mt-1 text-slate-600">{type === 'received' ? `Received: ${formatINR(review.totalReceivedPaise + paise!)} · Pending: ${formatINR(review.pendingToReceivePaise - paise!)} · Held: ${formatINR(review.heldBalancePaise + paise!)}` : `Refunded: ${formatINR(review.totalRefundedPaise + paise!)} · Held: ${formatINR(review.heldBalancePaise - paise!)}`}</p></div>}<div className="mt-6 flex justify-end gap-2"><Button variant="outline" disabled={busy} onClick={confirm ? () => setConfirm(false) : close}>{confirm ? 'Back' : 'Cancel'}</Button><Button disabled={!valid} loading={busy} onClick={confirm ? () => submit() : () => setConfirm(true)}>{confirm ? `Confirm ${type === 'received' ? 'receipt' : 'refund'}` : 'Review'}</Button></div></>}</section></div>;
}

function SecurityDepositCore({ agreement, workspaceId, role, tenantName, propertyName, unitName }: { agreement: Agreement; workspaceId: string; role: string; tenantName: string; propertyName: string; unitName: string }) {
  const [summary, setSummary] = useState<DepositSummary | null>(null);
  const [history, setHistory] = useState<DepositTransaction[] | null>(null);
  const [error, setError] = useState('');
  const [historyError, setHistoryError] = useState('');
  const [retry, setRetry] = useState(0);
  const [action, setAction] = useState<DepositTransactionType | null>(null);
  const [success, setSuccess] = useState<{ movement: DepositTransaction; summary: DepositSummary } | null>(null);
  useEffect(() => { setSummary(null); setError(''); return listenDepositSummary(workspaceId, agreement.id, setSummary, cause => setError(cause.message)); }, [workspaceId, agreement.id, agreement.securityDepositAgreedPaise, retry]);
  useEffect(() => { setHistory(null); setHistoryError(''); return listenDepositTransactions(workspaceId, agreement.id, setHistory, cause => setHistoryError(cause.message)); }, [workspaceId, agreement.id, retry]);
  const canWrite = financialRole(role);
  return <div className="space-y-5"><SectionCard title="Security Deposit" action={<span className="text-xs font-semibold uppercase tracking-wider text-slate-400">Separate from rent</span>}>{error ? <ToastNotice tone="danger" message={error} /> : !summary ? <div className="grid grid-cols-2 gap-3 sm:grid-cols-5">{Array.from({ length: 5 }, (_, i) => <Skeleton className="h-20" key={i} />)}</div> : <><div className="grid grid-cols-2 gap-3 sm:grid-cols-5"><Metric label="Agreed" amount={summary.agreedAmountPaise} /><Metric label="Received" amount={summary.totalReceivedPaise} /><Metric label="Pending" amount={summary.pendingToReceivePaise} /><Metric label="Refunded" amount={summary.totalRefundedPaise} /><Metric label="Currently held" amount={summary.heldBalancePaise} /></div>{agreement.status === 'ended' && summary.heldBalancePaise > 0 && <div className="mt-4"><ToastNotice message={`Deposit still held: ${formatINR(summary.heldBalancePaise)}`} /></div>}<div className="mt-5 flex flex-wrap gap-2">{canWrite && summary.pendingToReceivePaise > 0 && <Button onClick={() => { setSuccess(null); setAction('received'); }}>Receive Deposit</Button>}{canWrite && summary.heldBalancePaise > 0 && <Button variant="outline" onClick={() => { setSuccess(null); setAction('refunded'); }}>Refund Deposit</Button>}<a href={`#deposit-history-${agreement.id}`} className="inline-flex min-h-10 items-center rounded-xl px-4 text-sm font-semibold text-brand hover:bg-violet-50">View History</a></div></>}{error && <Button className="mt-4" variant="outline" onClick={() => setRetry(value => value + 1)}>Retry loading</Button>}</SectionCard>{success && <ToastNotice tone="success" message={success.movement.transactionType === 'received' ? `Received ${formatINR(success.movement.amountPaise)} · Total received ${formatINR(success.summary.totalReceivedPaise)} · Pending ${formatINR(success.summary.pendingToReceivePaise)} · Held ${formatINR(success.summary.heldBalancePaise)}` : `Refunded ${formatINR(success.movement.amountPaise)} · Total refunded ${formatINR(success.summary.totalRefundedPaise)} · Held ${formatINR(success.summary.heldBalancePaise)}`} />}<div id={`deposit-history-${agreement.id}`}><SectionCard title="Transaction History">{historyError ? <><ToastNotice tone="danger" message={historyError} /><Button className="mt-4" variant="outline" onClick={() => setRetry(value => value + 1)}>Retry history</Button></> : history === null ? <Skeleton className="h-28" /> : history.length === 0 ? <EmptyState title="No deposit transactions yet" body="Individual collections and refunds will appear here, even after the agreement ends." /> : <div className="overflow-x-auto"><table className="w-full min-w-[680px] text-sm"><thead className="text-left text-xs text-slate-500"><tr><th className="pb-3">Date</th><th>Type</th><th>Amount</th><th>Mode</th><th>Reference / Notes</th><th>Recorded by</th><th>Receipt</th></tr></thead><tbody>{history.map(item => <tr className="border-t border-slate-100" key={item.id}><td className="py-3">{displayDate(item.transactionDate.toDate())}</td><td><span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${item.transactionType === 'received' ? 'bg-emerald-50 text-emerald-800' : 'bg-blue-50 text-blue-800'}`}>{item.transactionType === 'received' ? 'Received' : 'Refunded'}</span></td><td className="font-semibold tabular-nums">{formatINR(item.amountPaise)}</td><td className="capitalize">{item.paymentMode.replace('_', ' ')}</td><td><p>{item.referenceNumber || '—'}</p>{item.notes && <p className="max-w-xs text-xs text-slate-500">{item.notes}</p>}</td><td className="max-w-28 truncate text-xs text-slate-500" title={item.createdBy}>{item.createdBy}</td><td><button className="font-semibold text-brand" onClick={() => window.dispatchEvent(new CustomEvent('creovy:view-deposit-receipt', { detail: { agreementId: agreement.id, transactionId: item.id } }))}>View Receipt</button></td></tr>)}</tbody></table></div>}</SectionCard></div>{action && summary && <MovementForm key={`${agreement.id}-${action}-${success?.movement.id ?? ''}`} workspaceId={workspaceId} agreement={agreement} summary={summary} type={action} tenantName={tenantName} propertyName={propertyName} unitName={unitName} close={() => setAction(null)} completed={(movement, latest) => { setAction(null); setSummary(latest); setSuccess({ movement, summary: latest }); }} />}</div>;
}

export function SecurityDepositDetail(props: { agreement: Agreement; workspaceId: string; role: string; tenantName: string; propertyName: string; unitName: string }) {
  const [ledger, setLedger] = useState<DepositLedgerEntry[] | null>(null);
  const [ledgerError, setLedgerError] = useState('');
  const [ledgerRetry, setLedgerRetry] = useState(0);
  const [receiptId, setReceiptId] = useState<string | null>(null);
  const [recentReceiptId, setRecentReceiptId] = useState<string | null>(null);
  useEffect(() => { setLedger(null); setLedgerError(''); return listenDepositLedger(props.workspaceId, props.agreement.id, setLedger, cause => setLedgerError(cause.message)); }, [props.workspaceId, props.agreement.id, ledgerRetry]);
  useEffect(() => {
    const onRecorded = (event: Event) => {
      const detail = (event as CustomEvent<{ agreementId: string; transactionId: string }>).detail;
      if (detail.agreementId === props.agreement.id) setRecentReceiptId(detail.transactionId);
    };
    window.addEventListener('creovy:deposit-recorded', onRecorded);
    return () => window.removeEventListener('creovy:deposit-recorded', onRecorded);
  }, [props.agreement.id]);
  useEffect(() => {
    const onReceipt = (event: Event) => {
      const detail = (event as CustomEvent<{ agreementId: string; transactionId: string }>).detail;
      if (detail.agreementId === props.agreement.id) setReceiptId(detail.transactionId);
    };
    window.addEventListener('creovy:view-deposit-receipt', onReceipt);
    return () => window.removeEventListener('creovy:view-deposit-receipt', onReceipt);
  }, [props.agreement.id]);
  return <><SecurityDepositCore {...props} />{recentReceiptId && <div className="mt-5 flex flex-wrap items-center justify-between gap-3 rounded-xl border border-emerald-200 bg-emerald-50 p-4"><p className="text-sm font-medium text-emerald-900">Deposit movement recorded. Its dedicated receipt is ready.</p><Button variant="outline" onClick={() => setReceiptId(recentReceiptId)}>View Receipt</Button></div>}<div id={`deposit-ledger-${props.agreement.id}`} className="mt-5"><SectionCard title="Deposit Ledger & Receipts">{ledgerError ? <><ToastNotice tone="danger" message={ledgerError} /><Button className="mt-3" variant="outline" onClick={() => setLedgerRetry(value => value + 1)}>Retry ledger</Button></> : ledger === null ? <Skeleton className="h-28" /> : ledger.length === 0 ? <EmptyState title="No deposit ledger entries" body="New collections and refunds create immutable ledger entries. Earlier development transactions are not automatically backfilled." /> : <><div className="mb-4 flex justify-end"><Button variant="outline" onClick={() => setReceiptId(ledger[ledger.length - 1].depositReceiptId)}>View latest receipt</Button></div><div className="overflow-x-auto"><table className="w-full min-w-[680px] text-left text-sm"><thead className="text-xs text-slate-500"><tr><th className="pb-3">Date</th><th>Type</th><th>Tenant</th><th>Property / Unit</th><th>Amount</th><th>Mode</th><th>Receipt</th></tr></thead><tbody>{ledger.map(entry => <tr key={entry.id} className="border-t border-slate-100"><td className="py-3">{displayDate(entry.transactionDate.toDate())}</td><td><span className={`rounded-full px-2.5 py-1 text-xs font-semibold ${entry.entryType === 'deposit_received' ? 'bg-emerald-50 text-emerald-800' : 'bg-blue-50 text-blue-800'}`}>{entry.entryType === 'deposit_received' ? 'Received' : 'Refunded'}</span></td><td>{props.tenantName}</td><td>{props.propertyName} · {props.unitName}</td><td className="font-semibold">{formatINR(entry.amountPaise)}</td><td className="capitalize">{entry.paymentMode.replace('_', ' ')}</td><td><button className="font-semibold text-brand" onClick={() => setReceiptId(entry.depositReceiptId)}>View Receipt</button></td></tr>)}</tbody></table></div></>}</SectionCard></div>{receiptId && <DepositReceiptDetail workspaceId={props.workspaceId} transactionId={receiptId} close={() => setReceiptId(null)} viewLedger={() => document.getElementById(`deposit-ledger-${props.agreement.id}`)?.scrollIntoView({ behavior: 'smooth' })} />}</>;
}

export function AdvancesPage({ workspaceId, role }: { workspaceId: string; role: string }) {
  const [agreements, setAgreements] = useState<Agreement[] | null>(null);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [properties, setProperties] = useState<Property[]>([]);
  const [units, setUnits] = useState<Unit[]>([]);
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState('all');
  const [selected, setSelected] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [retry, setRetry] = useState(0);
  useEffect(() => listenAgreements(workspaceId, setAgreements, cause => setError(cause.message)), [workspaceId, retry]);
  useEffect(() => listenTenants(workspaceId, setTenants, cause => setError(cause.message)), [workspaceId, retry]);
  useEffect(() => listenProperties(workspaceId, setProperties, cause => setError(cause.message)), [workspaceId, retry]);
  useEffect(() => listenAllUnits(workspaceId, setUnits, cause => setError(cause.message)), [workspaceId, retry]);
  const visible = (agreements ?? []).filter(item => (filter === 'all' || item.status === filter) && `${tenants.find(t => t.id === item.tenantId)?.fullName ?? ''} ${properties.find(p => p.id === item.propertyId)?.name ?? ''} ${units.find(u => u.id === item.unitId)?.name ?? ''}`.toLowerCase().includes(search.toLowerCase()));
  const agreement = agreements?.find(item => item.id === selected);
  return <div className="space-y-6"><div><p className="text-sm font-medium text-brand">ADVANCES · SECURITY DEPOSITS</p><h1 className="mt-1 text-3xl font-semibold">Security Deposits</h1><p className="mt-2 text-sm text-slate-500">Contractual deposits, actual collections, refunds, and balances held—separate from rent.</p></div>{error && <><ToastNotice tone="danger" message={error} /><Button variant="outline" onClick={() => { setError(''); setRetry(value => value + 1); }}>Retry</Button></>}<div className="grid gap-3 sm:grid-cols-[1fr_180px]"><input value={search} onChange={event => setSearch(event.target.value)} placeholder="Search tenant, property, or unit" aria-label="Search agreements" className="rounded-xl border border-slate-200 bg-white px-4 py-3" /><select value={filter} onChange={event => setFilter(event.target.value)} aria-label="Filter agreement status" className="rounded-xl border border-slate-200 bg-white px-4 py-3"><option value="all">All agreements</option><option value="active">Active</option><option value="ended">Ended</option><option value="upcoming">Upcoming</option><option value="draft">Draft</option><option value="cancelled">Cancelled</option></select></div><div className="grid gap-5 xl:grid-cols-[minmax(300px,360px)_1fr]"><SectionCard title={`Agreements${agreements ? ` · ${visible.length}` : ''}`}>{agreements === null ? <Skeleton className="h-44" /> : visible.length === 0 ? <EmptyState title="No matching agreements" body="Adjust your search or filter to find a deposit." /> : <div className="max-h-[70vh] space-y-2 overflow-y-auto">{visible.map(item => <button key={item.id} onClick={() => setSelected(item.id)} className={`w-full rounded-xl border p-3 text-left transition hover:border-brand ${selected === item.id ? 'border-brand bg-violet-50' : 'border-slate-200'}`}><span className="block font-semibold">{tenants.find(t => t.id === item.tenantId)?.fullName ?? 'Tenant'}</span><span className="mt-1 block text-xs text-slate-500">{properties.find(p => p.id === item.propertyId)?.name ?? 'Property'} · {units.find(u => u.id === item.unitId)?.name ?? 'Unit'} · {item.status}</span><span className="mt-2 block text-sm font-semibold">Agreed {formatINR(item.securityDepositAgreedPaise)}</span></button>)}</div>}</SectionCard><div>{agreement ? <SecurityDepositDetail key={agreement.id} agreement={agreement} workspaceId={workspaceId} role={role} tenantName={tenants.find(t => t.id === agreement.tenantId)?.fullName ?? 'Tenant'} propertyName={properties.find(p => p.id === agreement.propertyId)?.name ?? 'Property'} unitName={units.find(u => u.id === agreement.unitId)?.name ?? 'Unit'} /> : <EmptyState title="Select an agreement" body="Choose an agreement to see its live deposit balance and transaction history." />}</div></div></div>;
}
