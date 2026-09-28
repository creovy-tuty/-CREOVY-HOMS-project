export const tokens = {
  colors: {
    brand: '#5635D9', accent: '#008B8B', canvas: '#F6F7FB', surface: '#FFFFFF', elevated: '#FFFFFF',
    ink: '#172033', secondary: '#526174', muted: '#8390A2', border: '#E5E9F0', divider: '#EEF1F5',
    success: '#16794A', warning: '#A86600', danger: '#C2352B', info: '#2463B8',
    pending: '#A86600', partial: '#2463B8', paid: '#16794A', overdue: '#C2352B', vacant: '#64748B', occupied: '#5635D9',
  },
  radius: { control: '0.75rem', card: '1rem', panel: '1.25rem' },
} as const;

export const formatINR = (paise?: number) => {
  if (paise === undefined) return '—';
  const amount = BigInt(paise);
  const absolute = amount < 0n ? -amount : amount;
  const minor = absolute % 100n;
  return `${amount < 0n ? '-' : ''}₹${(absolute / 100n).toLocaleString('en-IN')}${minor === 0n ? '' : `.${minor.toString().padStart(2, '0')}`}`;
};
export const formatDate = (date: Date) => new Intl.DateTimeFormat('en-GB', { day: '2-digit', month: '2-digit', year: 'numeric', timeZone: 'Asia/Kolkata' }).format(date);
