import { db } from '@/lib/db';

export const dynamic = 'force-dynamic';

interface Source {
  key: string; label: string; cadence: string; engine: string; enabled: boolean;
  last_run: string | null; last_status: string | null; last_error: string | null;
  row_count: number | null; notes: string | null;
}

export default async function Sources() {
  const { data, error } = await db().from('sources').select('*').order('enabled', { ascending: false }).order('key');
  if (error) throw new Error(error.message);
  const rows = (data ?? []) as Source[];
  const fmt = (d: string | null) =>
    d ? new Date(d).toLocaleString('en-US', { timeZone: 'America/New_York', dateStyle: 'medium', timeStyle: 'short' }) : 'Never';

  return (
    <>
      <h1>Sources</h1>
      <p className="meta">Feed health. Cron feeds run on Vercel; Claude feeds run as scheduled tasks and report here when they write.</p>
      <div className="table-wrap section">
        <table className="grid">
          <thead>
            <tr><th>Source</th><th>Engine</th><th>Cadence</th><th>Last run (ET)</th><th>Status</th><th className="num">Rows</th><th>Notes</th></tr>
          </thead>
          <tbody>
            {rows.map((s) => (
              <tr key={s.key}>
                <td><strong>{s.label}</strong><div className="meta">{s.key}{s.enabled ? '' : ' (off)'}</div></td>
                <td>{s.engine}</td>
                <td>{s.cadence}</td>
                <td>{fmt(s.last_run)}</td>
                <td>
                  <span className={s.last_status === 'ok' ? 'status-ok' : s.last_status === 'error' ? 'status-error' : 'status-none'}>
                    {s.last_status ?? 'none'}
                  </span>
                  {s.last_error && <div className="meta" style={{ maxWidth: 320 }}>{s.last_error}</div>}
                </td>
                <td className="num">{s.row_count ?? ''}</td>
                <td className="meta" style={{ maxWidth: 280 }}>{s.notes}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
