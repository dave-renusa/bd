import { NextResponse } from 'next/server';
import { enabledFootprint, rpc, settingNumber } from '../db';
import { fetchPjmQueue, normalizePjm, parsePjmQueue } from './pjm';
import { fetchSabin, normalizeContested, normalizeRestrictions } from './sabin';

// Rows per RPC call. Keeps each call well under the Data API statement timeout.
const CHUNK = 400;

/** Vercel Cron sends `Authorization: Bearer $CRON_SECRET`. */
export function authorized(req: Request): boolean {
  const secret = process.env.CRON_SECRET;
  return !!secret && req.headers.get('authorization') === `Bearer ${secret}`;
}

/** Runs a job, records the outcome in bd.sources / bd.source_runs, returns JSON. */
export async function runJob(req: Request, key: string, job: () => Promise<{ rows?: number; detail: Record<string, unknown> }>) {
  if (!authorized(req)) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const started = new Date().toISOString();
  try {
    const { rows, detail } = await job();
    await rpc('record_source_run', { p_key: key, p_status: 'ok', p_row_count: rows ?? null, p_detail: detail, p_started_at: started });
    return NextResponse.json({ ok: true, key, rows, detail });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await rpc('record_source_run', { p_key: key, p_status: 'error', p_error: message.slice(0, 2000), p_started_at: started }).catch(() => {});
    return NextResponse.json({ ok: false, key, error: message }, { status: 500 });
  }
}

function sumCounts(results: Record<string, number>[]): Record<string, number> {
  const out: Record<string, number> = {};
  for (const r of results) for (const [k, v] of Object.entries(r)) out[k] = (out[k] ?? 0) + (Number(v) || 0);
  return out;
}

export async function runPjm() {
  const [footprint, mwFloor] = await Promise.all([enabledFootprint(), settingNumber('mw_floor', 50)]);
  const rawRows = await parsePjmQueue(await fetchPjmQueue());
  if (rawRows.length === 0) throw new Error('PJM queue file parsed to zero rows; the format may have changed.');
  const rows = normalizePjm(rawRows, { mwFloor, footprint });
  const results: Record<string, number>[] = [];
  for (let i = 0; i < rows.length; i += CHUNK) {
    results.push(await rpc('ingest_queue', { p_source: 'pjm_queue', p_iso: 'PJM', p_rows: rows.slice(i, i + CHUNK) }));
  }
  const scoring = await rpc('run_scoring');
  return { rows: rows.length, detail: { file_rows: rawRows.length, in_scope: rows.length, ...sumCounts(results), scoring } };
}

export async function runSabin() {
  const { restrictions, contested, urls } = await fetchSabin();
  const r = normalizeRestrictions(restrictions);
  const c = normalizeContested(contested);
  // One call so the snapshot recompute sees both files together.
  const result = await rpc<Record<string, number>>('ingest_sabin', { p_restrictions: r, p_contested: c });
  const scoring = await rpc('run_scoring');
  return {
    rows: r.length + c.length,
    detail: { ...urls, restriction_rows: restrictions.length, contested_rows: contested.length, ...result, scoring },
  };
}
