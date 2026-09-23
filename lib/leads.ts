import { db, settingNumber } from './db';

import type { LeadStage } from './stages';
export { LEAD_STAGES, type LeadStage } from './stages';
import { projectStageLabel } from './stages';

export interface Reason { factor: string; key: string; points: number; label: string; detail?: string | null }
export interface Breakdown {
  total?: number; fit?: number; stage?: number; pain?: number; access?: number; competition?: number;
  reasons?: Reason[];
  last_activity?: string | null;
  stale?: boolean;
}

export interface LeadRow {
  id: string;
  kind: string;
  display_name: string;
  score: number;
  score_breakdown: Breakdown;
  stage: LeadStage;
  closed_reason: string | null;
  owner: string | null;
  next_action: string | null;
  next_action_date: string | null;
  why_now: string | null;
  snoozed_until: string | null;
  qualified_at: string | null;
  created_at: string;
  subject_technology: string | null;
  subject_state: string | null;
  subject_fips: string | null;
  project_stage: string | null;
  place_name: string | null;
  county_name: string | null;
  risk_tier: number | null;
  restriction_type: string | null;
  mw_ac: number | null;
  mw_storage: number | null;
  acres: number | null;
  iso: string | null;
  queue_id: string | null;
  developer_name: string | null;
  developer_parent: string | null;
  last_signal_at: string | null;
  signal_count: number | null;
  latest_headline: string | null;
  latest_url: string | null;
}

export const LEAD_COLUMNS =
  'id, kind, display_name, score, score_breakdown, stage, closed_reason, owner, next_action, next_action_date, why_now, ' +
  'snoozed_until, qualified_at, created_at, subject_technology, subject_state, subject_fips, project_stage, place_name, ' +
  'county_name, risk_tier, restriction_type, mw_ac, mw_storage, acres, iso, queue_id, developer_name, ' +
  'developer_parent, last_signal_at, signal_count, latest_headline, latest_url';

export async function owners(): Promise<string[]> {
  const { data } = await db().from('settings').select('value').eq('key', 'owners').maybeSingle();
  return Array.isArray(data?.value) ? (data!.value as string[]) : ['Dave', 'Kate', 'Ben'];
}

export const thresholds = async () => ({
  qualify: await settingNumber('qualify_threshold', 70),
  signal: await settingNumber('signal_threshold', 50),
});

const today = () => new Date().toISOString().slice(0, 10);
const notSnoozed = () => `snoozed_until.is.null,snoozed_until.lte.${today()}`;

/** Leads that crossed the qualify threshold in the last 24 hours. */
export async function crossedSinceYesterday(): Promise<LeadRow[]> {
  const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
  const { data, error } = await db().from('lead_view').select(LEAD_COLUMNS)
    .gte('qualified_at', since).or(notSnoozed()).order('score', { ascending: false }).limit(50);
  if (error) throw new Error(error.message);
  return (data ?? []) as unknown as LeadRow[];
}

/** Open leads with a signal observed in the last 7 days. */
export async function newThisWeek(minScore: number): Promise<LeadRow[]> {
  const since = new Date(Date.now() - 7 * 24 * 3600 * 1000).toISOString();
  const { data, error } = await db().from('lead_view').select(LEAD_COLUMNS)
    .gte('last_signal_at', since).gte('score', minScore).neq('stage', 'Closed')
    .or(notSnoozed()).order('score', { ascending: false }).order('last_signal_at', { ascending: false }).limit(100);
  if (error) throw new Error(error.message);
  return (data ?? []) as unknown as LeadRow[];
}

export interface PipelineFilters {
  q?: string; stage?: string; owner?: string; tech?: string; state?: string; kind?: string; min?: number;
  includeClosed?: boolean;
}

export const SEARCH_LIMIT = 500;

/** Filters and keyword search, via bd.search_leads. Keywords also match signal text. */
export async function pipeline(f: PipelineFilters): Promise<LeadRow[]> {
  const { data, error } = await db().rpc('search_leads', {
    p_q: f.q?.trim() || null,
    p_state: f.state || null,
    p_tech: f.tech || null,
    p_kind: f.kind || null,
    p_stage: f.stage || null,
    p_owner: f.owner || null,
    p_min: f.min ?? 0,
    p_limit: SEARCH_LIMIT,
    p_include_closed: f.includeClosed ?? false,
  }).select(LEAD_COLUMNS);
  if (error) throw new Error(`search_leads: ${error.message}`);
  return (data ?? []) as unknown as LeadRow[];
}

export const techLabel = (t: string | null) =>
  ({ solar: 'Solar', wind: 'Wind', bess: 'BESS', solar_bess: 'Solar + BESS', data_center: 'Data center',
     transmission: 'Transmission', other: 'Other' } as Record<string, string>)[t ?? ''] ?? 'Unknown';

export const stageLabel = projectStageLabel;

/** "Mar 2022" from the score's last_activity date, or null. */
export const lastActivity = (b: Breakdown | null | undefined) =>
  b?.last_activity
    ? new Date(`${b.last_activity}T12:00:00Z`).toLocaleDateString('en-US', { month: 'short', year: 'numeric', timeZone: 'UTC' })
    : null;

/** A signal URL safe to link to, or null. Feeds sometimes store citation text. */
export const linkable = (u: string | null) => (u && /^https?:\/\/\S+$/i.test(u) ? u : null);
