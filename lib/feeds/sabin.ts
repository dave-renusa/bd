// Sabin Center Opposition Report feed (oppositionreport.org).
//
// The site publishes a Restriction file and a Contested Project file, updated
// monthly. Their exact URLs and column names were not verifiable from the
// build environment [UNVERIFIED], so:
//   - the files are found by scanning the current-report page for .xlsx/.csv
//     links whose name mentions "restrict" or "contest", unless
//     SABIN_RESTRICTIONS_URL / SABIN_CONTESTED_URL are set;
//   - columns are matched by a list of likely header names. Check the first
//     run's counts on /sources and add aliases here if a column is missed.
import { createHash } from 'node:crypto';
import { columnPicker, rawRow, readSheet, toIsoDate, toNumber, toText, type Row } from '../sheets';
import { toStateCode } from '../states';
import type { Technology } from './pjm';

export const SABIN_PAGE = 'https://oppositionreport.org/reports/current/';

const H = {
  state: ['State'],
  county: ['County', 'County Name', 'Counties'],
  locality: ['Locality', 'Municipality', 'Jurisdiction', 'Town', 'Township', 'City', 'Local Government', 'Locality Name'],
  restrictionType: ['Type of Restriction', 'Restriction Type', 'Type', 'Category', 'Restriction'],
  summary: ['Description', 'Summary', 'Details', 'Restriction Description', 'Notes', 'Project Description'],
  technology: ['Technology', 'Energy Type', 'Project Type', 'Resource', 'Facility Type', 'Energy Source'],
  effective: ['Effective Date', 'Date Enacted', 'Enacted', 'Date', 'Year'],
  until: ['Expiration', 'Expires', 'End Date', 'Moratorium End'],
  url: ['Source', 'Link', 'URL', 'Citation', 'Sources'],
  projectName: ['Project Name', 'Project', 'Name'],
  developer: ['Developer', 'Company', 'Applicant'],
  mw: ['Capacity (MW)', 'Capacity', 'MW', 'Size (MW)', 'Nameplate Capacity'],
  status: ['Status', 'Outcome', 'Current Status', 'Project Status'],
  decisionDate: ['Decision Date', 'Date of Decision', 'Outcome Date'],
};

const hash = (...parts: (string | null | undefined)[]) =>
  createHash('sha1').update(parts.map((p) => (p ?? '').toLowerCase().trim()).join('|')).digest('hex').slice(0, 16);

export function sabinTechnologies(v: string | null): Technology[] {
  const s = (v ?? '').toLowerCase();
  const out: Technology[] = [];
  if (s.includes('solar')) out.push('solar');
  if (s.includes('wind')) out.push('wind');
  if (s.includes('storage') || s.includes('battery') || s.includes('bess')) out.push('bess');
  if (s.includes('transmission')) out.push('transmission');
  return out;
}

function singleTechnology(v: string | null): Technology | null {
  const t = sabinTechnologies(v);
  if (t.includes('solar') && t.includes('bess')) return 'solar_bess';
  return t[0] ?? null;
}

/** Maps a free-text outcome to a project stage. Unknown means still contested. */
export function sabinStage(status: string | null): string {
  const s = (status ?? '').toLowerCase();
  if (/withdr|cancel|abandon|terminat/.test(s)) return 'withdrawn';
  if (/denied|rejected|blocked|defeated/.test(s)) return 'denied';
  if (/tabled|postponed|delayed|paused/.test(s)) return 'tabled';
  if (/approved|permitted|operational|built|construction|complete/.test(s)) return 'approved';
  return 'contested';
}

export interface SabinRestriction {
  key: string; state: string; county: string | null; locality: string | null;
  restriction_type: string | null; summary: string | null; technologies: string[] | null;
  effective: string | null; is_moratorium: boolean; moratorium_until: string | null;
  url: string | null; raw: Record<string, unknown>;
}

export interface SabinContested {
  key: string; state: string; county: string | null; locality: string | null;
  project_name: string | null; developer: string | null; technology: Technology | null;
  mw: number | null; status: string | null; stage: string; stage_at: string | null;
  summary: string | null; url: string | null; raw: Record<string, unknown>;
}

export function normalizeRestrictions(rows: Row[]): SabinRestriction[] {
  const col = columnPicker(rows[0]);
  const out: SabinRestriction[] = [];
  for (const row of rows) {
    const state = toStateCode(col(row, H.state));
    if (!state) continue;
    const county = toText(col(row, H.county));
    const locality = toText(col(row, H.locality));
    const type = toText(col(row, H.restrictionType));
    const summary = toText(col(row, H.summary));
    const techs = sabinTechnologies(toText(col(row, H.technology)));
    out.push({
      key: hash(state, county, locality, type, summary?.slice(0, 120)),
      state, county, locality,
      restriction_type: type,
      summary,
      technologies: techs.length ? techs : null,
      effective: toIsoDate(col(row, H.effective)),
      is_moratorium: /moratori/i.test(`${type ?? ''} ${summary ?? ''}`),
      moratorium_until: toIsoDate(col(row, H.until)),
      url: toText(col(row, H.url)),
      raw: rawRow(row),
    });
  }
  return out;
}

export function normalizeContested(rows: Row[]): SabinContested[] {
  const col = columnPicker(rows[0]);
  const out: SabinContested[] = [];
  for (const row of rows) {
    const state = toStateCode(col(row, H.state));
    if (!state) continue;
    const county = toText(col(row, H.county));
    const locality = toText(col(row, H.locality));
    const name = toText(col(row, H.projectName));
    const status = toText(col(row, H.status));
    out.push({
      key: hash(state, county, locality, name),
      state, county, locality,
      project_name: name,
      developer: toText(col(row, H.developer)),
      technology: singleTechnology(toText(col(row, H.technology))),
      mw: toNumber(col(row, H.mw)),
      status,
      stage: sabinStage(status),
      stage_at: toIsoDate(col(row, H.decisionDate)),
      summary: toText(col(row, H.summary)),
      url: toText(col(row, H.url)),
      raw: rawRow(row),
    });
  }
  return out;
}

/** Finds the two data-file links on the current-report page. */
export function findSabinLinks(html: string, base = SABIN_PAGE): { restrictions?: string; contested?: string } {
  const links = [...html.matchAll(/href\s*=\s*["']([^"']+\.(?:xlsx|xls|csv)(?:\?[^"']*)?)["']/gi)]
    .map((m) => new URL(m[1], base).toString());
  return {
    restrictions: links.find((l) => /restrict/i.test(l)),
    contested: links.find((l) => /contest/i.test(l)),
  };
}

async function download(url: string): Promise<ArrayBuffer> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`Sabin download failed for ${url}: HTTP ${res.status}`);
  return res.arrayBuffer();
}

export async function fetchSabin(): Promise<{ restrictions: Row[]; contested: Row[]; urls: Record<string, string | undefined> }> {
  let restrictionsUrl = process.env.SABIN_RESTRICTIONS_URL;
  let contestedUrl = process.env.SABIN_CONTESTED_URL;
  if (!restrictionsUrl || !contestedUrl) {
    const res = await fetch(SABIN_PAGE);
    if (!res.ok) throw new Error(`Sabin page fetch failed: HTTP ${res.status}`);
    const found = findSabinLinks(await res.text());
    restrictionsUrl ||= found.restrictions;
    contestedUrl ||= found.contested;
  }
  if (!restrictionsUrl && !contestedUrl) {
    throw new Error('No Sabin data links found on the report page. Set SABIN_RESTRICTIONS_URL and SABIN_CONTESTED_URL.');
  }
  const hints = ['State', 'County'];
  const [restrictions, contested] = await Promise.all([
    restrictionsUrl ? download(restrictionsUrl).then((b) => readSheet(b, hints)) : Promise.resolve([]),
    contestedUrl ? download(contestedUrl).then((b) => readSheet(b, hints)) : Promise.resolve([]),
  ]);
  return { restrictions, contested, urls: { restrictionsUrl, contestedUrl } };
}
