import type { Config } from 'tailwindcss';
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  theme: { extend: { colors: { ink: '#172033', brand: '#5635D9', accent: '#008B8B', mist: '#F6F7FB', danger: '#C2352B' }, boxShadow: { soft: '0 12px 32px rgba(23,32,51,.08)' } } },
  plugins: [],
} satisfies Config;
