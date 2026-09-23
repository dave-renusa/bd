import Link from 'next/link';
import LeadCard from './lead-card';
import { crossedSinceYesterday, newThisWeek, owners, thresholds } from '@/lib/leads';

export const dynamic = 'force-dynamic';

export default async function Today({ searchParams }: { searchParams: Promise<{ all?: string }> }) {
  const { all } = await searchParams;
  const t = await thresholds();
  const showAll = all === '1';
  const [crossed, week, ownerList] = await Promise.all([
    crossedSinceYesterday(),
    newThisWeek(showAll ? 0 : t.signal),
    owners(),
  ]);
  const crossedIds = new Set(crossed.map((l) => l.id));
  const rest = week.filter((l) => !crossedIds.has(l.id));
  const dateLabel = new Date().toLocaleDateString('en-US', {
    weekday: 'long', month: 'long', day: 'numeric', timeZone: 'America/New_York',
  });

  return (
    <>
      <h1>Today</h1>
      <p className="meta">{dateLabel}</p>

      <section className="section">
        <div className="section-head">
          <h2>Crossed {t.qualify} since yesterday</h2>
          <span className="meta">{crossed.length} lead{crossed.length === 1 ? '' : 's'}</span>
        </div>
        {crossed.length === 0
          ? <div className="empty">Nothing crossed {t.qualify} in the last 24 hours.</div>
          : <div className="cards">{crossed.map((l) => <LeadCard key={l.id} lead={l} owners={ownerList} qualify={t.qualify} />)}</div>}
      </section>

      <section className="section">
        <div className="section-head">
          <h2>New this week</h2>
          <span className="meta">
            {rest.length} lead{rest.length === 1 ? '' : 's'} with a signal in the last 7 days
            {showAll ? ', all scores. ' : `, score ${t.signal}+. `}
            <Link href={showAll ? '/' : '/?all=1'}>{showAll ? `Hide under ${t.signal}` : `Show under ${t.signal}`}</Link>
          </span>
        </div>
        {rest.length === 0
          ? <div className="empty">No new signals this week{showAll ? '' : ` at ${t.signal} or above`}.</div>
          : <div className="cards">{rest.map((l) => <LeadCard key={l.id} lead={l} owners={ownerList} qualify={t.qualify} />)}</div>}
      </section>
    </>
  );
}
