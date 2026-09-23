// PJM interconnection queue feed.
//
// Source: the Excel export behind PJM's public New Services Queue page
// (https://www.pjm.com/planning/services-requests/interconnection-queues).
// The page's "Export" button POSTs to services.pjm.com with a subscription key
// that is embedded in PJM's own page JavaScript; the open-source gridstatus
// library uses the same route. PJM can rotate that key or the column names
// without notice [UNVERIFIED stability], so both are overridable:
//   PJM_QUEUE_FILE_URL          GET a queue file from here instead (xlsx or csv)
//   PJM_QUEUE_SUBSCRIPTION_KEY  override the page's embedded key
//   PJM_API_KEY                 reserved for a registered Data Miner 2 key (not used yet)
import { columnPicker, rawRow, readSheet, toIsoDate, toNumber, toText, type Row } from '../sheets';
import { toStateCode } from '../states';

export const PJM_QUEUE_PAGE = 'https://www.pjm.com/planning/services-requests/interconnection-queues';
export const PJM_EXPORT_URL = 'https://services.pjm.com/PJMPlanningApi/api/Queue/ExportToXls';
// Public key embedded in pjm.com's queue page script (as found by gridstatus).
const PJM_PAGE_KEY = 'E29477D0-70E0-4825-89B0-43F460BF9AB4';

export type Technology = 'solar' | 'wind' | 'bess' | 'solar_bess' | 'data_center' | 'transmission' | 'other';

export interface QueueRow {
  queue_id: string;
  name: string;
  developer: string | null;
  technology: Technology;
  mw_ac: number | null;
  mw_storage: number | null;
  state: string;
  county: string | null;
  status: string | null;
  is_withdrawn: boolean;
  is_built: boolean;
  entered_at: string | null;
  url: string;
  raw: Record<string, unknown>;
}

export async function fetchPjmQueue(): Promise<ArrayBuffer> {
  const fileUrl = process.env.PJM_QUEUE_FILE_URL;
  const res = fileUrl
    ? await fetch(fileUrl)
    : await fetch(PJM_EXPORT_URL, {
        method: 'POST',
        headers: {
          'api-subscription-key': process.env.PJM_QUEUE_SUBSCRIPTION_KEY || PJM_PAGE_KEY,
          Origin: 'https://www.pjm.com',
          Referer: 'https://www.pjm.com/',
        },
      });
  if (!res.ok) throw new Error(`PJM queue download failed: HTTP ${res.status} ${res.statusText}`);
  return res.arrayBuffer();
}

export async function parsePjmQueue(buf: ArrayBuffer | Buffer): Promise<Row[]> {
  return readSheet(buf, ['Project ID', 'Queue Number', 'Queue ID']);
}

/** Maps PJM's Fuel column to a technology. */
export function pjmTechnology(fuel: string | null): Technology {
  const f = (fuel ?? '').toLowerCase();
  const solar = f.includes('solar');
  const storage = f.includes('storage') || f.includes('battery');
  const wind = f.includes('wind');
  if (solar && storage) return 'solar_bess';
  if (solar) return 'solar';
  if (wind) return 'wind';
  if (storage) return 'bess';
  return 'other';
}

const WITHDRAWN = /withdrawn|retracted|deactivated|annulled|terminated|cancel/i;
const BUILT = /in service|under construction|partially in service|operational/i;

export interface NormalizeOptions {
  mwFloor: number;
  footprint: Set<string>;
}

/**
 * Normalizes PJM rows and keeps in-scope ones: solar, wind or storage, at or
 * above the MW floor, in a footprint state. Withdrawn and built rows are kept
 * so tracked projects get status-change signals; the database never creates
 * a new project from them.
 */
export function normalizePjm(rows: Row[], opts: NormalizeOptions): QueueRow[] {
  const col = columnPicker(rows[0]);
  const out: QueueRow[] = [];
  for (const row of rows) {
    // PJM appends transition notes ("AH1-716 - moved to TC2"); keep only the ID so notes can change freely.
    const queueId = toText(col(row, ['Project ID', 'Queue Number', 'Queue ID', 'Queue Position']))?.split(' - ')[0].trim();
    if (!queueId) continue;
    const technology = pjmTechnology(toText(col(row, ['Fuel', 'Fuel Type', 'Generation Type'])));
    if (technology === 'other') continue;
    const state = toStateCode(col(row, ['State']));
    if (!state || !opts.footprint.has(state)) continue;

    const mfo = toNumber(col(row, ['MFO', 'Maximum Facility Output']));
    const mwEnergy = toNumber(col(row, ['MW Energy']));
    const mwCapacity = toNumber(col(row, ['MW Capacity']));
    const mw = mfo ?? Math.max(mwEnergy ?? 0, mwCapacity ?? 0);
    if (!mw || mw < opts.mwFloor) continue;

    const status = toText(col(row, ['Status']));
    const commercial = toText(col(row, ['Commercial Name']));
    const name = toText(col(row, ['Name', 'Project Name']));
    out.push({
      queue_id: queueId,
      name: commercial || name || queueId,
      // The public export has no interconnecting-entity column; enrichment resolves the developer.
      developer: toText(col(row, ['Interconnecting Entity', 'Developer', 'Interconnection Customer'])),
      technology,
      mw_ac: mw,
      mw_storage: technology === 'bess' || technology === 'solar_bess' ? mw : null,
      state,
      county: toText(col(row, ['County'])),
      status,
      is_withdrawn: WITHDRAWN.test(status ?? ''),
      is_built: BUILT.test(status ?? ''),
      entered_at: toIsoDate(col(row, ['Submitted Date', 'Queue Date', 'Request Received'])),
      url: PJM_QUEUE_PAGE,
      raw: rawRow(row),
    });
  }
  return out;
}
