-- BD Radar: core schema.
-- Everything lives in the `bd` schema. Nothing in `public` is touched.
-- Access model for the proof of concept: RLS on, no policies. Only the
-- service_role (server-side Next.js code, Vercel cron, Claude tasks via REST)
-- can read or write. anon and authenticated get nothing.

create schema if not exists bd;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

create type bd.technology as enum (
  'solar', 'wind', 'bess', 'solar_bess', 'data_center', 'transmission', 'other'
);

create type bd.project_stage as enum (
  'queue', 'state_prefiling', 'local_preapp', 'filed', 'contested', 'hearing',
  'denied', 'tabled', 'approved', 'withdrawn', 'moratorium_blocked'
);

create type bd.signal_source as enum (
  'pjm_queue', 'miso_queue', 'nyiso_queue', 'isone_queue', 'ercot_gis',
  'ercot_large_load', 'spp_queue', 'duke_queue', 'dominion_queue',
  'southern_queue', 'tva_queue', 'sabin_restriction', 'sabin_contested',
  'eia860m', 'greenlight', 'opposition_web', 'opposition_petition',
  'people_move', 'developer_hiring', 'tdlr', 'usace', 'state_docket',
  'county_agenda', 'news', 'manual'
);

create type bd.signal_type as enum (
  'queue_entry', 'queue_status_change', 'restriction_enacted', 'moratorium',
  'opposition_group', 'petition', 'hearing_scheduled', 'denied', 'tabled',
  'approved', 'withdrawn', 'job_change', 'hiring', 'permit_filed',
  'docket_filed', 'news'
);

create type bd.lead_stage as enum (
  'Signal', 'Qualified', 'Contacted', 'Conversation', 'Proposal', 'Won', 'Lost', 'Watch'
);

create type bd.lead_kind as enum ('project', 'developer', 'jurisdiction', 'person');
create type bd.draft_channel as enum ('email', 'linkedin');
create type bd.alert_kind as enum ('daily', 'weekly');
create type bd.people_event_type as enum ('title_change', 'company_change', 'new_hire_at_target');

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function bd.touch_updated_at() returns trigger
language plpgsql set search_path = bd, pg_temp as $$
begin
  new.updated_at = now();
  return new;
end $$;

-- Normalizes a county name so "St. Mary's County", "Saint Marys" and
-- "ST MARYS" all match. Keeps "city" because Virginia and Maryland have
-- independent cities that share names with counties (Baltimore city vs
-- Baltimore County).
create or replace function bd.norm_county(p text) returns text
language sql immutable set search_path = bd, pg_temp as $$
  select nullif(trim(regexp_replace(
    regexp_replace(
      regexp_replace(
        regexp_replace(lower(coalesce(p, '')), '[^a-z0-9 ]', '', 'g'),
        '\s+(county|parish|borough|census area|city and borough|municipality)$', ''),
      '^saint\s+', 'st '),
    '\s+', ' ', 'g')), '')
$$;

-- True when two technologies overlap (solar_bess overlaps solar and bess).
create or replace function bd.tech_overlap(a bd.technology, b bd.technology) returns boolean
language sql immutable set search_path = bd, pg_temp as $$
  select a = b
      or (a = 'solar_bess' and b in ('solar', 'bess'))
      or (b = 'solar_bess' and a in ('solar', 'bess'))
$$;

-- ---------------------------------------------------------------------------
-- Configuration tables (editable from /settings without a deploy)
-- ---------------------------------------------------------------------------

create table bd.footprint (
  state char(2) primary key,
  state_name text not null,
  enabled boolean not null default false,
  team text,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);

create table bd.score_weights (
  key text primary key,
  factor text not null check (factor in ('fit', 'stage', 'pain', 'access', 'competition')),
  points integer not null,
  description text not null,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);

create table bd.settings (
  key text primary key,
  value jsonb not null,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);

-- ---------------------------------------------------------------------------
-- Core tables
-- ---------------------------------------------------------------------------

create table bd.jurisdictions (
  fips text primary key,               -- 5-digit county FIPS; state rows use SS000
  kind text not null default 'county' check (kind in ('state', 'county')),
  state char(2) not null,
  county text,                         -- county name as published (null for state rows)
  name text not null,                  -- display name, e.g. "Loudoun County, VA"
  norm_name text generated always as (bd.norm_county(county)) stored,
  has_restriction boolean not null default false,
  restriction_type text,
  restriction_summary text,
  restriction_effective date,
  has_moratorium boolean not null default false,
  moratorium_until date,
  contested_project_count integer not null default 0,
  sabin_updated_at timestamptz,
  risk_tier smallint not null default 1 check (risk_tier between 1 and 5),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);
create index jurisdictions_state_norm_idx on bd.jurisdictions (state, norm_name);

create table bd.developers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  parent_name text,
  hq_state char(2),
  website text,
  technologies bd.technology[] not null default '{}',
  known_to_renusa boolean not null default false,
  relationship_notes text,
  linkedin_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);
create unique index developers_name_key on bd.developers (lower(name));

create table bd.projects (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  developer_id uuid references bd.developers (id) on delete set null,
  developer_raw text,                  -- entity name exactly as the source published it
  technology bd.technology not null default 'other',
  mw_ac numeric,
  mw_storage numeric,
  sq_ft numeric,
  acres numeric,
  state char(2),
  county text,
  fips text references bd.jurisdictions (fips),
  jurisdiction_name text,              -- municipality or township when narrower than county
  iso text,
  queue_id text,
  queue_entered_at date,
  stage bd.project_stage not null default 'queue',
  stage_changed_at timestamptz not null default now(),
  status_source text,                  -- raw status string from the feed, used for diffing
  external_key text unique,            -- stable key for non-queue sources (sabin:..., manual:...)
  lat double precision,
  lng double precision,
  first_seen_at timestamptz not null default now(),
  last_signal_at timestamptz,
  is_noise boolean not null default false,
  raw jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);
create unique index projects_iso_queue_key on bd.projects (iso, queue_id) where queue_id is not null;
create index projects_fips_idx on bd.projects (fips);
create index projects_developer_idx on bd.projects (developer_id);

create table bd.people (
  id uuid primary key default gen_random_uuid(),
  full_name text not null,
  current_company text,
  current_title text,
  developer_id uuid references bd.developers (id) on delete set null,
  linkedin_url text,
  email text,
  relationship_owner text,             -- Dave | Kate | Ben | other
  relationship_strength smallint check (relationship_strength between 1 and 3),
  source text not null default 'import' check (source in ('import', 'discovered')),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);
create index people_developer_idx on bd.people (developer_id);

create table bd.people_events (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references bd.people (id) on delete cascade,
  developer_id uuid references bd.developers (id) on delete set null,
  event_type bd.people_event_type not null,
  detail text,
  url text,
  observed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);

create table bd.leads (
  id uuid primary key default gen_random_uuid(),
  kind bd.lead_kind not null,
  title text not null,
  external_key text unique,
  project_id uuid references bd.projects (id) on delete cascade,
  developer_id uuid references bd.developers (id) on delete set null,
  person_id uuid references bd.people (id) on delete set null,
  jurisdiction_fips text references bd.jurisdictions (fips),
  jurisdiction_name text,
  -- Subject fields for leads without a project (jurisdiction, developer, person).
  -- Project leads read these from bd.projects instead.
  technology bd.technology,
  state char(2),
  subject_stage bd.project_stage,
  subject_stage_at timestamptz,
  competitor_present boolean not null default false,
  competitor_note text,
  score integer not null default 0,
  score_breakdown jsonb not null default '{}',
  scored_at timestamptz,
  qualified_at timestamptz,            -- first time the score reached the qualify threshold
  stage bd.lead_stage not null default 'Signal',
  stage_changed_at timestamptz not null default now(),
  owner text,
  next_action text,
  next_action_date date,
  why_now text,
  snoozed_until date,
  closed_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);
create unique index leads_project_key on bd.leads (project_id) where kind = 'project';
create index leads_score_idx on bd.leads (score desc);
create index leads_qualified_idx on bd.leads (qualified_at desc);

create table bd.signals (
  id uuid primary key default gen_random_uuid(),
  project_id uuid references bd.projects (id) on delete set null,
  developer_id uuid references bd.developers (id) on delete set null,
  lead_id uuid references bd.leads (id) on delete set null,
  jurisdiction_fips text references bd.jurisdictions (fips),
  source bd.signal_source not null,
  signal_type bd.signal_type not null,
  headline text not null,
  detail text,
  url text,
  observed_at timestamptz not null default now(),
  raw jsonb,
  dedupe_key text not null unique,
  is_noise boolean not null default false,
  enriched_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);
create index signals_project_idx on bd.signals (project_id);
create index signals_lead_idx on bd.signals (lead_id);
create index signals_fips_idx on bd.signals (jurisdiction_fips);
create index signals_observed_idx on bd.signals (observed_at desc);
create index signals_unenriched_idx on bd.signals (created_at) where enriched_at is null;

create table bd.lead_notes (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references bd.leads (id) on delete cascade,
  author text not null,
  body text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);

create table bd.outreach_drafts (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid not null references bd.leads (id) on delete cascade,
  recipient_person_id uuid references bd.people (id) on delete set null,
  channel bd.draft_channel not null default 'email',
  subject text,
  body text not null,
  generated_at timestamptz not null default now(),
  approved boolean not null default false,   -- never auto-sent
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);

create table bd.alerts (
  id uuid primary key default gen_random_uuid(),
  lead_id uuid references bd.leads (id) on delete cascade,
  kind bd.alert_kind not null,
  sent_at timestamptz not null default now(),
  recipients text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);

create table bd.sources (
  key text primary key,
  label text not null,
  cadence text not null,
  engine text not null default 'cron' check (engine in ('cron', 'claude', 'manual')),
  last_run timestamptz,
  last_status text,
  last_error text,
  row_count integer,
  enabled boolean not null default false,
  footprint text[] not null default '{all}',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);

create table bd.source_runs (
  id uuid primary key default gen_random_uuid(),
  source_key text not null references bd.sources (key) on delete cascade,
  started_at timestamptz,
  finished_at timestamptz not null default now(),
  status text not null,
  row_count integer,
  error text,
  detail jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by text
);
create index source_runs_key_idx on bd.source_runs (source_key, finished_at desc);

-- updated_at triggers on every table
do $$
declare t text;
begin
  foreach t in array array[
    'footprint', 'score_weights', 'settings', 'jurisdictions', 'developers',
    'projects', 'people', 'people_events', 'leads', 'signals', 'lead_notes',
    'outreach_drafts', 'alerts', 'sources', 'source_runs'
  ] loop
    execute format(
      'create trigger %I before update on bd.%I for each row execute function bd.touch_updated_at()',
      t || '_touch', t);
    execute format('alter table bd.%I enable row level security', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Grants: service_role only
-- ---------------------------------------------------------------------------

revoke all on schema bd from public;
grant usage on schema bd to service_role;
grant all on all tables in schema bd to service_role;
grant all on all sequences in schema bd to service_role;
alter default privileges in schema bd grant all on tables to service_role;
alter default privileges in schema bd grant all on sequences to service_role;
alter default privileges in schema bd grant execute on functions to service_role;
