import { useEffect, useRef, useState } from 'react';
import { Button, Skeleton } from '../../design/components';
import { formatINR } from '../../design/tokens';
import { getDepositReceipt, type DepositReceipt } from './security-deposit-financial-repository';

const dateLabel = (date: Date) => new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' }).format(date);
const modeLabel = (value: string) => ({ cash: 'Cash', upi: 'UPI', bank_transfer: 'Bank transfer', cheque: 'Cheque', other: 'Other' })[value as 'cash'] ?? 'Other';
export const depositReceiptFilename = (number: string) => `CREOVY-HOMS-Deposit-${number.startsWith('CRV-D-F-') ? 'Refund-' : 'Receipt-'}${number.replace(/[^a-zA-Z0-9-]/g, '-')}.pdf`;

export function DepositReceiptDetail({ workspaceId, transactionId, close, viewLedger }: { workspaceId: string; transactionId: string; close: () => void; viewLedger?: () => void }) {
  const [receipt, setReceipt] = useState<DepositReceipt | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [revision, setRevision] = useState(0);
  const [busy, setBusy] = useState(false);
  const root = useRef<HTMLElement>(null);
  useEffect(() => {
    let active = true;
    setLoading(true); setError(''); setReceipt(null);
    getDepositReceipt(workspaceId, transactionId).then(value => { if (active) { setReceipt(value); setLoading(false); } })
      .catch(cause => { if (active) { setError(cause instanceof Error ? cause.message : 'Receipt unavailable.'); setLoading(false); } });
    return () => { active = false; };
  }, [workspaceId, transactionId, revision]);
  const download = async () => {
    if (!receipt || !root.current || busy) return;
    setBusy(true); setError('');
    try {
      const [{ jsPDF }, { default: html2canvas }] = await Promise.all([import('jspdf'), import('html2canvas')]);
      const canvas = await html2canvas(root.current, { scale: 2, backgroundColor: '#ffffff' });
      const pdf = new jsPDF({ unit: 'mm', format: 'a4' });
      const scale = Math.min(182 / canvas.width, 269 / canvas.height);
      pdf.addImage(canvas.toDataURL('image/png'), 'PNG', (210 - canvas.width * scale) / 2, 14, canvas.width * scale, canvas.height * scale);
      pdf.save(depositReceiptFilename(receipt.receiptNumber));
    } catch { setError('PDF could not be prepared. Use Print to save as PDF.'); }
    finally { setBusy(false); }
  };
  return <div className="fixed inset-0 z-[70] overflow-y-auto bg-ink/40 p-3 print:static print:bg-white print:p-0 sm:p-7"><div className="mx-auto max-w-[794px] space-y-4"><div className="flex flex-wrap items-center justify-between gap-2 print:hidden"><Button variant="outline" onClick={close}>← Back to deposit</Button><div className="flex gap-2"><Button variant="outline" disabled={!receipt} onClick={() => window.print()}>Print</Button><Button disabled={!receipt || busy} onClick={download}>{busy ? 'Preparing PDF…' : 'Download PDF'}</Button></div></div>{loading ? <div className="space-y-3"><Skeleton className="h-24" /><Skeleton className="h-80" /></div> : error && !receipt ? <div role="alert" className="rounded-xl bg-white p-6 text-red-800">{error} <button className="font-semibold underline" onClick={() => setRevision(value => value + 1)}>Retry</button></div> : !receipt ? <div className="rounded-xl bg-white p-6 text-amber-900">No receipt exists for this transaction. Pre-Step 7C movements are not automatically backfilled.</div> : <><article ref={root} className="receipt-print-root bg-white p-7 shadow-soft sm:p-12 print:p-0 print:shadow-none" aria-label="Security deposit receipt"><header className="border-b border-slate-200 pb-7"><p className="text-sm font-bold tracking-[.16em] text-brand">CREOVY HOMS</p><h1 className="mt-6 text-3xl font-semibold">{receipt.transactionType === 'received' ? 'SECURITY DEPOSIT RECEIPT' : 'SECURITY DEPOSIT REFUND RECEIPT'}</h1><p className="mt-2 text-sm text-slate-500">{receipt.receiptNumber}</p></header><div className="grid gap-6 border-b border-slate-200 py-7 sm:grid-cols-2"><div><p className="text-xs uppercase tracking-widest text-slate-400">Tenant</p><p className="mt-1 text-lg font-semibold">{receipt.tenantName}</p></div><div><p className="text-xs uppercase tracking-widest text-slate-400">Property / Unit</p><p className="mt-1 text-lg font-semibold">{receipt.propertyName}</p><p>{receipt.unitName}</p></div></div><dl className="grid gap-4 py-7 text-sm sm:grid-cols-2">{[['Agreement', receipt.agreementId], ['Transaction', receipt.depositTransactionId], ['Type', receipt.transactionType === 'received' ? 'Deposit received' : 'Deposit refunded'], ['Date', dateLabel(receipt.transactionDate.toDate())], ['Payment mode', modeLabel(receipt.paymentMode)], ...(receipt.referenceNumber ? [['Reference', receipt.referenceNumber]] : [])].map(([label, value]) => <div key={label}><dt className="text-slate-500">{label}</dt><dd className="mt-1 break-all font-semibold">{value}</dd></div>)}</dl><div className="rounded-xl bg-slate-50 p-6"><p className="text-xs font-bold uppercase tracking-wider text-slate-500">{receipt.transactionType === 'received' ? 'Amount received' : 'Amount refunded'}</p><p className="mt-1 text-3xl font-semibold text-brand">{formatINR(receipt.amountPaise)}</p><div className="mt-4 grid gap-2 text-sm sm:grid-cols-3"><p>Deposit agreed<br /><strong>{formatINR(receipt.agreedAmountPaise)}</strong></p><p>Total received after movement<br /><strong>{formatINR(receipt.totalReceivedPaise)}</strong></p><p>Held after movement<br /><strong>{formatINR(receipt.heldBalancePaise)}</strong></p></div></div><p className="mt-5 text-xs text-slate-500">Property owner's security-deposit record. This does not state that CREOVY received or refunded the money.</p><footer className="mt-16 border-t border-slate-200 pt-5 text-xs text-slate-500">Generated by CREOVY HOMS</footer></article>{error && <div className="rounded-xl bg-red-50 p-3 text-sm text-red-800">{error}</div>}{viewLedger && <div className="print:hidden"><Button variant="outline" onClick={() => { close(); viewLedger(); }}>View deposit ledger →</Button></div>}</>}</div></div>;
}
