import { useEffect, useState } from 'react';
import { Skeleton } from '../../design/components';
import { formatINR } from '../../design/tokens';
import { currentPeriodKey, isOverdue, listenRentDues, type RentDue } from './rent-due-repository';
import { ensureRentDues } from './rent-due-repository';
import { listenAgreements } from '../tenants/tenant-repository';

function Metric({ label, amount, note, tone }: { label: string; amount?: number; note?: string; tone: string }) {
  return <div className="rounded-2xl border border-slate-200 bg-white p-5"><p className="text-sm text-slate-500">{label}</p>{amount === undefined ? <Skeleton className="mt-3 h-7 w-28" /> : <p className="mt-3 text-2xl font-semibold tabular-nums text-ink">{formatINR(amount)}</p>}{note && <p className="mt-2 text-xs text-slate-400">{note}</p>}<span className={`mt-4 inline-block h-1.5 w-10 rounded-full ${tone}`} /></div>;
}

export function DashboardRentMetrics({ workspaceId }: { workspaceId: string }) {
  const [dues, setDues] = useState<RentDue[] | null>(null);
  const [error, setError] = useState(false);
  const [prepared, setPrepared] = useState(false);
  useEffect(() => listenRentDues(workspaceId, setDues, () => setError(true)), [workspaceId]);
  useEffect(() => {
    let lastSignature: string | null = null;
    return listenAgreements(workspaceId, agreements => {
      const signature = agreements.map(item => `${item.id}:${item.status}:${item.startDate}:${item.endDate ?? ''}`).sort().join('|');
      if (signature === lastSignature) return;
      lastSignature = signature;
      setPrepared(false);
      ensureRentDues(workspaceId, agreements).then(() => setPrepared(true)).catch(() => setError(true));
    }, () => setError(true));
  }, [workspaceId]);
  const month = currentPeriodKey();
  const current = prepared ? dues?.filter(due => due.periodKey === month) : null;
  const expected = current?.reduce((sum, due) => sum + due.rentAmountPaise, 0);
  const collected = current?.reduce((sum, due) => sum + due.totalPaidPaise, 0);
  const outstanding = current?.reduce((sum, due) => sum + due.balancePaise, 0);
  const overdue = prepared ? dues?.filter(isOverdue).reduce((sum, due) => sum + due.balancePaise, 0) : undefined;
  return <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
    <Metric label="Expected Rent" amount={expected} note="Current month" tone="bg-violet-400" />
    <Metric label="Collected Rent" amount={collected} note="Current month" tone="bg-emerald-500" />
    <Metric label="Current Outstanding" amount={outstanding} note="Current month only" tone="bg-amber-400" />
    <Metric label="Overdue" amount={overdue} note="All outstanding overdue periods" tone="bg-red-400" />
    {error && <p role="alert" className="text-sm text-red-700">Rent metrics are temporarily unavailable.</p>}
  </div>;
}
