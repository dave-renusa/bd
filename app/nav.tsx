'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/', label: 'Today' },
  { href: '/pipeline', label: 'Pipeline' },
  { href: '/sources', label: 'Sources' },
];

export default function Nav() {
  const path = usePathname();
  return (
    <nav className="nav">
      {TABS.map((t) => (
        <Link key={t.href} href={t.href} className={path === t.href ? 'active' : undefined}>
          {t.label}
        </Link>
      ))}
    </nav>
  );
}
