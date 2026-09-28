import { useEffect, useRef, useState } from 'react';
import { Button, Skeleton } from '../../design/components';
import { formatDate, formatINR } from '../../design/tokens';
import { getReceiptByPayment, type RentReceipt } from './financial-record-repository';

export const receiptFilename = (number: string) => `CREOVY-HOMS-Receipt-${number.replace(/[^a-zA-Z0-9-]/g, '-')}.pdf`;
const modeLabel = (mode: string) => ({ cash: 'Cash', upi: 'UPI', bank_transfer: 'Bank Transfer', cheque: 'Cheque', other: 'Other' })[mode as 'cash'] ?? 'Other';
const periodLabel = (period: string) => /^\d{4}-\d{2}$/.test(period) ? `${period.slice(5)}/${period.slice(0, 4)}` : period;

export function ReceiptPage({ workspaceId, paymentId, back, viewLedger }: { workspaceId: string; paymentId: string; back: () => void; viewLedger: (tenantId: string) => void }) {
  const [receipt, setReceipt] = useState<RentReceipt | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [revision, setRevision] = useState(0);
  const receiptRef = useRef<HTMLElement>(null);
  useEffect(() => {
    let active = true;
    setLoading(true); setError(''); setReceipt(null);
    getReceiptByPayment(workspaceId, paymentId).then(item => { if (active) { setReceipt(item); setLoading(false); } }).catch(() => { if (active) { setError('Receipt could not be loaded.'); setLoading(false); } });
    return () => { active = false; };
  }, [workspaceId, paymentId, revision]);

  async function download() {
    if (!receipt || busy) return;
    setBusy(true); setError('');
    try {
      const element = receiptRef.current;
      if (!element) throw new Error('Receipt is not visible.');
      const [{ jsPDF }, { default: html2canvas }] = await Promise.all([import('jspdf'), import('html2canvas')]);
      const canvas = await html2canvas(element, { scale: 2, backgroundColor: '#ffffff' });
      const pdf = new jsPDF({ unit: 'mm', format: 'a4' });
      const scale = Math.min(182 / canvas.width, 269 / canvas.height);
      const width = canvas.width * scale;
      const height = canvas.height * scale;
      pdf.addImage(canvas.toDataURL('image/png'), 'PNG', (210 - width) / 2, 14, width, height);
      pdf.save(receiptFilename(receipt.receiptNumber));
    } catch { setError('PDF download could not be prepared. Try Print and save as PDF.'); }
    finally { setBusy(false); }
  }

  return <div className="space-y-5"><div className="flex flex-wrap items-center justify-between gap-3 print:hidden"><button onClick={back} className="font-semibold text-brand">← Back</button><div className="flex gap-2"><Button variant="outline" onClick={() => window.print()}>Print</Button><Button onClick={download} disabled={!receipt || busy}>{busy ? 'Preparing PDF…' : 'Download PDF'}</Button></div></div>
    {loading ? <div className="space-y-3"><Skeleton className="h-24" /><Skeleton className="h-72" /></div> : error ? <div role="alert" className="rounded-xl border border-red-200 bg-red-50 p-5 text-red-800">{error} <button onClick={() => setRevision(value => value + 1)} className="font-semibold underline">Retry</button></div> : !receipt ? <div className="rounded-xl border border-amber-200 bg-amber-50 p-5 text-amber-900">No receipt is available for this payment. Payments recorded before receipts were introduced may not have one.</div> : <>
      <article ref={receiptRef} className="receipt-print-root mx-auto w-full max-w-[794px] bg-white p-7 shadow-sm ring-1 ring-slate-200 sm:p-12 print:max-w-none print:p-0 print:shadow-none print:ring-0" aria-label="Rent receipt">
        <header className="border-b border-slate-200 pb-8"><p className="text-sm font-bold tracking-[.16em] text-brand">CREOVY HOMS</p><h1 className="mt-7 text-3xl font-semibold tracking-tight text-ink">RENT RECEIPT</h1><p className="mt-2 text-sm text-slate-500">{receipt.receiptNumber}</p></header>
        <div className="grid gap-8 border-b border-slate-200 py-8 sm:grid-cols-2"><div><p className="text-xs font-semibold uppercase tracking-widest text-slate-400">Tenant</p><p className="mt-2 text-lg font-semibold">{receipt.tenantName}</p></div><div><p className="text-xs font-semibold uppercase tracking-widest text-slate-400">Property / Unit</p><p className="mt-2 text-lg font-semibold">{receipt.propertyName}</p><p className="text-sm text-slate-600">{receipt.unitName}</p></div></div>
        <dl className="grid gap-5 py-8 text-sm sm:grid-cols-2">{[['Rent period', periodLabel(receipt.periodKey)], ['Payment date', formatDate(receipt.paymentDate.toDate())], ['Payment mode', modeLabel(receipt.paymentMode)], ['Receipt number', receipt.receiptNumber], ...(receipt.referenceNumber ? [['Reference number', receipt.referenceNumber]] : [])].map(([label, value]) => <div key={label}><dt className="text-slate-500">{label}</dt><dd className="mt-1 break-words font-semibold text-ink">{value}</dd></div>)}</dl>
        <div className="flex flex-wrap items-end justify-between gap-3 rounded-xl bg-slate-50 px-6 py-6"><p className="text-xs font-semibold uppercase tracking-widest text-slate-500">Amount received</p><p className="text-3xl font-semibold tabular-nums text-brand">{formatINR(receipt.amountPaise)}</p></div>
        <p className="mt-4 text-xs text-slate-500">Property owner rent collection record. This does not state that CREOVY received the payment.</p><footer className="mt-20 border-t border-slate-200 pt-5 text-xs text-slate-500">Generated by CREOVY HOMS</footer>
      </article><div className="mx-auto max-w-[794px] print:hidden"><button onClick={() => viewLedger(receipt.tenantId)} className="font-semibold text-brand">View Tenant Ledger →</button></div>
    </>}
  </div>;
}
