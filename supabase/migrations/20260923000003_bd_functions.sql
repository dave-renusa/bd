-- BD Radar: matching, ingestion, and scoring functions.
-- Feed modules in lib/feeds/ fetch and normalize rows, then hand them to these
-- functions over RPC, so diffing and scoring are deterministic and live in
-- one place.

-- Indexes the scoring subqueries rely on.
create index if not exists projects_fips_stage_idx on bd.projects (fips, stage);
create index if not exists signals_type_idx on bd.signals (signal_type);
create index if not exists signals_source_idx on bd.signals (source);

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

-- County FIPS for a state and county name. Takes the first county when the
-- source lists several ("Frederick; Clarke"). Returns null when no match.
create or replace function bd.match_county(p_state text, p_county text) returns text
language sql stable set search_path = bd, pg_temp as $$
  select j.fips
  from bd.jurisdictions j
  where j.kind = 'county'
    and j.state = upper(trim(p_state))
    and j.norm_name = bd.norm_county(split_part(regexp_replace(coalesce(p_county, ''), '[;/,&]| and ', ';', 'g'), ';', 1))
  order by j.fips
  limit 1
$$;

-- Finds or creates a developer by exact (case-insensitive) name.
create or replace function bd.upsert_developer(p_name text, p_tech bd.technology default null) returns uuid
language plpgsql set search_path = bd, pg_temp as $$
declare v_id uuid;
begin
  if p_name is null or trim(p_name) = '' then return null; end if;
  select id into v_id from bd.developers where lower(name) = lower(trim(p_name));
  if v_id is null then
    insert into bd.developers (name, technologies, created_by)
    values (trim(p_name), case when p_tech is null then '{}' else array[p_tech] end, 'feed')
    returning id into v_id;
  elsif p_tech is not null then
    update bd.developers set technologies = array_append(technologies, p_tech)
    where id = v_id and not (p_tech = any (technologies));
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Feed bookkeeping
-- ---------------------------------------------------------------------------

create or replace function bd.record_source_run(
  p_key text, p_status text, p_row_count integer default null,
  p_error text default null, p_detail jsonb default null, p_started_at timestamptz default null
) returns void
language plpgsql set search_path = bd, pg_temp as $$
begin
  update bd.sources
     set last_run = now(), last_status = p_status, last_error = p_error,
         row_count = coalesce(p_row_count, row_count)
   where key = p_key;
  insert into bd.source_runs (source_key, started_at, status, row_count, error, detail)
  values (p_key, p_started_at, p_status, p_row_count, p_error, p_detail);
end $$;

-- ---------------------------------------------------------------------------
-- Queue ingestion (PJM now; MISO, NYISO, ISO-NE, ERCOT, SPP reuse it)
-- ---------------------------------------------------------------------------
-- p_rows: array of {queue_id, name, developer, technology, mw_ac, mw_storage,
--   state, county, status, is_withdrawn, is_built, entered_at, url, raw}
-- is_built marks in-service or under-construction rows: they are tracked for
-- status changes but never create a new project.
-- Rows must already be filtered to in-scope technology, MW floor and footprint.
-- New active queue entries create a project and a queue_entry signal.
-- A changed status on a tracked project creates a status signal.
create or replace function bd.ingest_queue(p_source bd.signal_source, p_iso text, p_rows jsonb)
returns jsonb
language plpgsql set search_path = bd, pg_temp as $$
declare
  r record;
  v_proj bd.projects;
  v_fips text;
  v_dev uuid;
  v_new int := 0; v_changed int := 0; v_unchanged int := 0; v_skipped int := 0; v_unmatched int := 0;
  v_place text;
  v_sig_type bd.signal_type;
begin
  for r in
    select * from jsonb_to_recordset(p_rows) as x(
      queue_id text, name text, developer text, technology bd.technology,
      mw_ac numeric, mw_storage numeric, state text, county text, status text,
      is_withdrawn boolean, is_built boolean, entered_at date, url text, raw jsonb)
  loop
    if r.queue_id is null then v_skipped := v_skipped + 1; continue; end if;

    select * into v_proj from bd.projects where iso = p_iso and queue_id = r.queue_id;

    if v_proj.id is null then
      if coalesce(r.is_withdrawn, false) or coalesce(r.is_built, false) then
        v_skipped := v_skipped + 1; continue;
      end if;

      v_fips := bd.match_county(r.state, r.county);
      if v_fips is null then v_unmatched := v_unmatched + 1; end if;
      v_dev := bd.upsert_developer(r.developer, r.technology);
      v_place := coalesce((select name from bd.jurisdictions where fips = v_fips),
                          concat_ws(', ', nullif(r.county, ''), r.state));

      insert into bd.projects (
        name, developer_id, developer_raw, technology, mw_ac, mw_storage, state, county,
        fips, iso, queue_id, queue_entered_at, stage, stage_changed_at, status_source,
        last_signal_at, raw, created_by)
      values (
        coalesce(nullif(r.name, ''), r.queue_id), v_dev, r.developer, r.technology, r.mw_ac,
        r.mw_storage, upper(r.state), r.county, v_fips, p_iso, r.queue_id, r.entered_at, 'queue',
        coalesce(r.entered_at::timestamptz, now()), r.status,
        coalesce(r.entered_at::timestamptz, now()), r.raw, 'feed:' || p_source)
      returning * into v_proj;

      insert into bd.signals (project_id, developer_id, jurisdiction_fips, source, signal_type,
                              headline, detail, url, observed_at, raw, dedupe_key, created_by)
      values (
        v_proj.id, v_dev, v_fips, p_source, 'queue_entry',
        format('%s queue: %s, %s MW %s in %s', p_iso, v_proj.name,
               trim(to_char(coalesce(r.mw_ac, r.mw_storage), 'FM999999990.##')),
               replace(r.technology::text, '_', '+'), v_place),
        format('Queue %s, status %s, entered %s.', r.queue_id, coalesce(r.status, 'unknown'),
               coalesce(r.entered_at::text, 'unknown')),
        r.url, coalesce(r.entered_at::timestamptz, now()), r.raw,
        p_source || ':' || r.queue_id || ':entry', 'feed:' || p_source)
      on conflict (dedupe_key) do nothing;

      v_new := v_new + 1;

    elsif v_proj.status_source is distinct from r.status then
      v_sig_type := case when coalesce(r.is_withdrawn, false) then 'withdrawn' else 'queue_status_change' end;

      update bd.projects set
        status_source = r.status,
        stage = case when coalesce(r.is_withdrawn, false) then 'withdrawn'::bd.project_stage else stage end,
        stage_changed_at = case when coalesce(r.is_withdrawn, false) then now() else stage_changed_at end,
        mw_ac = coalesce(r.mw_ac, mw_ac),
        mw_storage = coalesce(r.mw_storage, mw_storage),
        last_signal_at = now(),
        raw = r.raw
      where id = v_proj.id;

      insert into bd.signals (project_id, developer_id, jurisdiction_fips, source, signal_type,
                              headline, detail, url, observed_at, raw, dedupe_key, created_by)
      values (
        v_proj.id, v_proj.developer_id, v_proj.fips, p_source, v_sig_type,
        format('%s queue %s: status %s to %s', p_iso, v_proj.name,
               coalesce(v_proj.status_source, 'unknown'), coalesce(r.status, 'unknown')),
        null, r.url, now(), r.raw,
        p_source || ':' || r.queue_id || ':status:' || coalesce(r.status, 'null'), 'feed:' || p_source)
      on conflict (dedupe_key) do nothing;

      v_changed := v_changed + 1;
    else
      v_unchanged := v_unchanged + 1;
    end if;
  end loop;

  return jsonb_build_object('new', v_new, 'changed', v_changed, 'unchanged', v_unchanged,
                            'skipped', v_skipped, 'county_unmatched', v_unmatched);
end $$;

-- ---------------------------------------------------------------------------
-- Sabin Center Opposition Report ingestion
-- ---------------------------------------------------------------------------
-- p_restrictions: array of {key, state, county, locality, restriction_type,
--   summary, technologies, effective, is_moratorium, moratorium_until, url, raw}
-- p_contested: array of {key, state, county, locality, project_name, developer,
--   technology, mw, status, stage, summary, url, raw}
-- Each file is a full snapshot, so jurisdiction flags are recomputed from it.
-- Pass an empty array to leave that half untouched.
create or replace function bd.ingest_sabin(p_restrictions jsonb, p_contested jsonb, p_as_of date default current_date)
returns jsonb
language plpgsql set search_path = bd, pg_temp as $$
declare
  v_r_total int := 0; v_r_matched int := 0; v_r_new int := 0;
  v_c_total int := 0; v_c_matched int := 0; v_c_new int := 0;
  v_rows int;
begin
  -- Restrictions -----------------------------------------------------------
  if jsonb_array_length(coalesce(p_restrictions, '[]')) > 0 then
    set local client_min_messages = warning;
    drop table if exists _sabin_r;
    create temp table _sabin_r on commit drop as
    select x.*,
           case when x.county is null or trim(x.county) = ''
                then (select fips from bd.jurisdictions where kind = 'state' and state = upper(trim(x.state)))
                else bd.match_county(x.state, x.county) end as fips
    from jsonb_to_recordset(p_restrictions) as x(
      key text, state text, county text, locality text, restriction_type text, summary text,
      technologies text[], effective date, is_moratorium boolean, moratorium_until date,
      url text, raw jsonb);

    select count(*), count(fips) into v_r_total, v_r_matched from _sabin_r;

    insert into bd.signals (jurisdiction_fips, source, signal_type, headline, detail, url,
                            observed_at, raw, dedupe_key, created_by)
    select fips, 'sabin_restriction',
           (case when coalesce(is_moratorium, false) then 'moratorium' else 'restriction_enacted' end)::bd.signal_type,
           left(format('%s: %s%s', concat_ws(', ', nullif(locality, ''), nullif(county, ''), upper(state)),
                  coalesce(restriction_type, 'restriction'),
                  case when technologies is null then '' else ' (' || array_to_string(technologies, ', ') || ')' end), 300),
           summary, url, coalesce(effective::timestamptz, p_as_of::timestamptz), raw,
           'sabin_r:' || key, 'feed:sabin'
    from _sabin_r
    where key is not null
    on conflict (dedupe_key) do nothing;
    get diagnostics v_rows = row_count;
    v_r_new := v_rows;

    update bd.jurisdictions j set
      has_restriction = false, restriction_type = null, restriction_summary = null,
      restriction_effective = null, has_moratorium = false, moratorium_until = null
    where j.has_restriction or j.has_moratorium;

    update bd.jurisdictions j set
      has_restriction = true,
      restriction_type = a.types,
      restriction_summary = a.summary,
      restriction_effective = a.effective,
      has_moratorium = a.has_moratorium,
      moratorium_until = a.moratorium_until,
      sabin_updated_at = now()
    from (
      select fips,
             left(string_agg(distinct restriction_type, '; '), 500) as types,
             left(string_agg(summary, ' | ' order by effective nulls last), 2000) as summary,
             min(effective) as effective,
             bool_or(coalesce(is_moratorium, false)) as has_moratorium,
             max(moratorium_until) as moratorium_until
      from _sabin_r where fips is not null group by fips
    ) a
    where j.fips = a.fips;
  end if;

  -- Contested projects -----------------------------------------------------
  if jsonb_array_length(coalesce(p_contested, '[]')) > 0 then
    set local client_min_messages = warning;
    drop table if exists _sabin_c;
    create temp table _sabin_c on commit drop as
    select x.*, bd.match_county(x.state, x.county) as fips
    from jsonb_to_recordset(p_contested) as x(
      key text, state text, county text, locality text, project_name text, developer text,
      technology bd.technology, mw numeric, status text, stage bd.project_stage, stage_at date,
      summary text, url text, raw jsonb);

    select count(*), count(fips) into v_c_total, v_c_matched from _sabin_c;

    -- Contested projects become project records so they can carry leads.
    -- stage_changed_at: the decision date when the file has one. An unknown date
    -- is treated as old so the project does not earn "within 12 months" points.
    insert into bd.projects (name, developer_id, developer_raw, technology, mw_ac, state, county,
                             fips, jurisdiction_name, stage, stage_changed_at, status_source,
                             external_key, last_signal_at, raw, created_by)
    select coalesce(nullif(c.project_name, ''), 'Contested project in ' || concat_ws(', ', c.county, c.state)),
           bd.upsert_developer(c.developer, c.technology), c.developer,
           coalesce(c.technology, 'other'), c.mw, upper(c.state), c.county, c.fips, c.locality,
           coalesce(c.stage, 'contested'), coalesce(c.stage_at::timestamptz, '2000-01-01'::timestamptz),
           c.status, 'sabin:' || c.key,
           p_as_of::timestamptz, c.raw, 'feed:sabin'
    from (select distinct on (key) * from _sabin_c where key is not null order by key) c
    on conflict (external_key) do update set
      stage = case when bd.projects.status_source is distinct from excluded.status_source
                   then excluded.stage else bd.projects.stage end,
      stage_changed_at = case when bd.projects.status_source is distinct from excluded.status_source
                   then now() else bd.projects.stage_changed_at end,
      status_source = excluded.status_source,
      raw = excluded.raw;

    insert into bd.signals (project_id, jurisdiction_fips, source, signal_type, headline, detail,
                            url, observed_at, raw, dedupe_key, created_by)
    select p.id, c.fips, 'sabin_contested', 'opposition_group',
           left(format('Contested: %s (%s)', p.name, concat_ws(', ', nullif(c.locality, ''), nullif(c.county, ''), upper(c.state))), 300),
           c.summary, c.url, p_as_of::timestamptz, c.raw,
           'sabin_c:' || c.key || ':' || coalesce(c.status, ''), 'feed:sabin'
    from _sabin_c c
    join bd.projects p on p.external_key = 'sabin:' || c.key
    on conflict (dedupe_key) do nothing;
    get diagnostics v_rows = row_count;
    v_c_new := v_rows;

    update bd.jurisdictions set contested_project_count = 0 where contested_project_count > 0;
    update bd.jurisdictions j set contested_project_count = a.n, sabin_updated_at = now()
    from (select fips, count(*) n from _sabin_c where fips is not null group by fips) a
    where j.fips = a.fips;
  end if;

  perform bd.refresh_jurisdiction_risk();

  return jsonb_build_object(
    'restrictions', v_r_total, 'restrictions_matched', v_r_matched, 'restriction_signals_new', v_r_new,
    'contested', v_c_total, 'contested_matched', v_c_matched, 'contested_signals_new', v_c_new);
end $$;

-- ---------------------------------------------------------------------------
-- County risk tier (1 to 5)
-- ---------------------------------------------------------------------------
-- 5 active moratorium (Sabin flag or a moratorium signal in the last 12 months)
-- 4 restriction and at least one contested project
-- 3 restriction, or two or more contested projects
-- 2 one contested project
-- 1 nothing on record
create or replace function bd.refresh_jurisdiction_risk() returns void
language sql set search_path = bd, pg_temp as $$
  update bd.jurisdictions j set risk_tier = t.tier
  from (
    select j2.fips,
      case
        when (j2.has_moratorium and (j2.moratorium_until is null or j2.moratorium_until >= current_date))
          or exists (select 1 from bd.signals s
                     where s.jurisdiction_fips = j2.fips and s.signal_type = 'moratorium'
                       and not s.is_noise and s.observed_at >= now() - interval '12 months') then 5
        when j2.has_restriction and j2.contested_project_count >= 1 then 4
        when j2.has_restriction or j2.contested_project_count >= 2 then 3
        when j2.contested_project_count = 1 then 2
        else 1
      end as tier
    from bd.jurisdictions j2
  ) t
  where j.fips = t.fips and j.risk_tier is distinct from t.tier
$$;

-- ---------------------------------------------------------------------------
-- Scoring
-- ---------------------------------------------------------------------------

create or replace function bd.setting_num(p_key text, p_default numeric) returns numeric
language sql stable set search_path = bd, pg_temp as $$
  select coalesce((select (value #>> '{}')::numeric from bd.settings where key = p_key), p_default)
$$;

-- Scores one lead. Returns the breakdown jsonb:
-- {total, fit, stage, pain, access, competition, reasons: [{factor, key, points, label}]}
create or replace function bd.score_lead(p_lead_id uuid) returns jsonb
language plpgsql stable set search_path = bd, pg_temp as $$
declare
  w jsonb;
  l bd.leads;
  p bd.projects;
  j bd.jurisdictions;
  v_tech bd.technology; v_state text; v_fips text; v_stage bd.project_stage;
  v_stage_at timestamptz; v_queue_at date; v_mw numeric; v_dev uuid;
  v_floor numeric := bd.setting_num('mw_floor', 50);
  fit int := 0; stg int := 0; pain int := 0; acc int := 0; comp int := 0;
  reasons jsonb := '[]';
  k text; v_strength int; pts int;
begin
  select coalesce(jsonb_object_agg(key, jsonb_build_object('p', points, 'd', description)), '{}')
    into w from bd.score_weights;

  select * into l from bd.leads where id = p_lead_id;
  if l.id is null then return null; end if;
  if l.project_id is not null then select * into p from bd.projects where id = l.project_id; end if;

  v_tech     := coalesce(p.technology, l.technology);
  v_state    := coalesce(p.state, l.state);
  v_fips     := coalesce(p.fips, l.jurisdiction_fips);
  v_stage    := coalesce(p.stage, l.subject_stage);
  v_stage_at := coalesce(p.stage_changed_at, l.subject_stage_at, l.created_at);
  v_queue_at := p.queue_entered_at;
  v_mw       := greatest(p.mw_ac, p.mw_storage);
  v_dev      := coalesce(p.developer_id, l.developer_id);
  if v_fips is not null then select * into j from bd.jurisdictions where fips = v_fips; end if;

  -- Fit ---------------------------------------------------------------------
  if v_tech in ('solar', 'wind', 'bess', 'solar_bess', 'data_center') then
    k := 'fit_technology'; pts := (w->k->>'p')::int; fit := fit + pts;
    reasons := reasons || jsonb_build_object('factor', 'fit', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;
  if exists (select 1 from bd.footprint f where f.state = v_state and f.enabled) then
    k := 'fit_footprint'; pts := (w->k->>'p')::int; fit := fit + pts;
    reasons := reasons || jsonb_build_object('factor', 'fit', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;
  if v_tech = 'data_center' or v_mw >= v_floor then
    k := 'fit_size'; pts := (w->k->>'p')::int; fit := fit + pts;
    reasons := reasons || jsonb_build_object('factor', 'fit', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;

  -- Stage -------------------------------------------------------------------
  k := case v_stage
    when 'queue' then case when coalesce(v_queue_at::timestamptz, v_stage_at) >= now() - interval '12 months'
                           then 'stage_queue_recent' else 'stage_queue_old' end
    when 'state_prefiling' then 'stage_state_prefiling'
    when 'local_preapp' then 'stage_local_preapp'
    when 'filed' then 'stage_filed'
    when 'hearing' then 'stage_hearing'
    when 'contested' then 'stage_contested'
    when 'denied' then case when v_stage_at >= now() - interval '12 months' then 'stage_denied_recent' else 'stage_denied_old' end
    when 'tabled' then case when v_stage_at >= now() - interval '12 months' then 'stage_denied_recent' else 'stage_denied_old' end
    when 'moratorium_blocked' then 'stage_moratorium'
    when 'approved' then 'stage_approved'
    when 'withdrawn' then 'stage_withdrawn'
    else null end;
  if k is not null then
    stg := coalesce((w->k->>'p')::int, 0);
    reasons := reasons || jsonb_build_object('factor', 'stage', 'key', k, 'points', stg, 'label', w->k->>'d');
  end if;

  -- Pain --------------------------------------------------------------------
  if j.has_restriction then
    k := 'pain_restriction'; pts := (w->k->>'p')::int; pain := pain + pts;
    reasons := reasons || jsonb_build_object('factor', 'pain', 'key', k, 'points', pts,
      'label', w->k->>'d', 'detail', j.restriction_type);
  end if;
  if (j.has_moratorium and (j.moratorium_until is null or j.moratorium_until >= current_date))
     or v_stage = 'moratorium_blocked'
     or exists (select 1 from bd.signals s
                left join bd.projects sp on sp.id = s.project_id
                left join bd.leads sl on sl.id = s.lead_id
                where s.signal_type = 'moratorium' and not s.is_noise
                  and s.observed_at >= now() - interval '12 months'
                  and (s.jurisdiction_fips = v_fips or s.project_id = l.project_id or s.lead_id = l.id)
                  -- a data center moratorium is no pain for a solar project, and vice versa
                  and (v_tech is null or coalesce(sp.technology, sl.technology) is null
                       or bd.tech_overlap(coalesce(sp.technology, sl.technology), v_tech))) then
    k := 'pain_moratorium'; pts := (w->k->>'p')::int; pain := pain + pts;
    reasons := reasons || jsonb_build_object('factor', 'pain', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;
  if exists (select 1 from bd.signals s
             where not s.is_noise
               and (s.signal_type in ('opposition_group', 'petition')
                    or s.source in ('opposition_web', 'opposition_petition', 'sabin_contested'))
               and (s.project_id = l.project_id or s.lead_id = l.id
                    or (l.project_id is null and s.jurisdiction_fips = v_fips))) then
    k := 'pain_opposition'; pts := (w->k->>'p')::int; pain := pain + pts;
    reasons := reasons || jsonb_build_object('factor', 'pain', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;
  if v_fips is not null and v_tech is not null and exists (
       select 1 from bd.projects o
       where o.fips = v_fips and o.stage = 'denied' and not o.is_noise
         and o.id is distinct from l.project_id and bd.tech_overlap(o.technology, v_tech)) then
    k := 'pain_prior_denial'; pts := (w->k->>'p')::int; pain := pain + pts;
    reasons := reasons || jsonb_build_object('factor', 'pain', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;
  pain := least(pain, coalesce((w->'pain_cap'->>'p')::int, 25));

  -- Access ------------------------------------------------------------------
  select max(pe.relationship_strength) into v_strength
  from bd.people pe
  where (v_dev is not null and pe.developer_id = v_dev) or pe.id = l.person_id;
  if v_strength is not null then
    k := 'access_strength_' || v_strength; pts := (w->k->>'p')::int; acc := acc + pts;
    reasons := reasons || jsonb_build_object('factor', 'access', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;
  if v_dev is not null and exists (select 1 from bd.developers d where d.id = v_dev and d.known_to_renusa) then
    k := 'access_known_dev'; pts := (w->k->>'p')::int; acc := acc + pts;
    reasons := reasons || jsonb_build_object('factor', 'access', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;
  if v_dev is not null and exists (
       select 1 from bd.people_events ev join bd.people pe on pe.id = ev.person_id
       where (ev.developer_id = v_dev or pe.developer_id = v_dev)
         and ev.observed_at >= now() - interval '90 days') then
    k := 'access_people_event'; pts := (w->k->>'p')::int; acc := acc + pts;
    reasons := reasons || jsonb_build_object('factor', 'access', 'key', k, 'points', pts, 'label', w->k->>'d');
  end if;
  acc := least(acc, coalesce((w->'access_cap'->>'p')::int, 25));

  -- Competition -------------------------------------------------------------
  if l.competitor_present then
    k := 'competition_penalty'; comp := -abs((w->k->>'p')::int);
    reasons := reasons || jsonb_build_object('factor', 'competition', 'key', k, 'points', comp,
      'label', w->k->>'d', 'detail', l.competitor_note);
  end if;

  return jsonb_build_object(
    'total', greatest(0, least(100, fit + stg + pain + acc + comp)),
    'fit', fit, 'stage', stg, 'pain', pain, 'access', acc, 'competition', comp,
    'reasons', reasons);
end $$;

-- Creates a project lead for every non-noise project that lacks one.
create or replace function bd.ensure_project_leads() returns integer
language plpgsql set search_path = bd, pg_temp as $$
declare n int;
begin
  insert into bd.leads (kind, title, project_id, developer_id, jurisdiction_fips, technology, state,
                        stage, created_by)
  select 'project', p.name, p.id, p.developer_id, p.fips, p.technology, p.state,
         case when p.stage = 'approved' then 'Watch'::bd.lead_stage else 'Signal'::bd.lead_stage end,
         'scoring'
  from bd.projects p
  where not p.is_noise
    and not exists (select 1 from bd.leads l where l.kind = 'project' and l.project_id = p.id);
  get diagnostics n = row_count;
  return n;
end $$;

-- Rescores every lead. Leads in Signal that reach the qualify threshold move
-- to Qualified, and qualified_at records the first crossing (the daily alert
-- keys on it).
create or replace function bd.rescore_leads() returns integer
language plpgsql set search_path = bd, pg_temp as $$
declare
  n int;
  v_threshold int := bd.setting_num('qualify_threshold', 70);
begin
  with s as (
    select l.id, bd.score_lead(l.id) as b from bd.leads l
  )
  update bd.leads l set
    score = (s.b->>'total')::int,
    score_breakdown = s.b,
    scored_at = now(),
    qualified_at = case when l.qualified_at is null and (s.b->>'total')::int >= v_threshold
                        then now() else l.qualified_at end,
    stage = case when l.stage = 'Signal' and (s.b->>'total')::int >= v_threshold
                 then 'Qualified'::bd.lead_stage else l.stage end,
    stage_changed_at = case when l.stage = 'Signal' and (s.b->>'total')::int >= v_threshold
                            then now() else l.stage_changed_at end
  from s
  where s.id = l.id
    -- skip unchanged leads so the nightly run stays fast
    and (l.score_breakdown is distinct from s.b
         or (l.stage = 'Signal' and (s.b->>'total')::int >= v_threshold));
  get diagnostics n = row_count;
  return n;
end $$;

-- Nightly entry point (and called after each feed run).
create or replace function bd.run_scoring() returns jsonb
language plpgsql set search_path = bd, pg_temp as $$
declare v_created int; v_scored int; v_qualified int;
begin
  perform bd.refresh_jurisdiction_risk();
  v_created := bd.ensure_project_leads();
  v_scored := bd.rescore_leads();
  select count(*) into v_qualified from bd.leads where qualified_at = now();
  return jsonb_build_object('leads_created', v_created, 'leads_changed', v_scored,
                            'newly_qualified', v_qualified);
end $$;

-- ---------------------------------------------------------------------------
-- Read model for the web app and the Claude tasks
-- ---------------------------------------------------------------------------

create or replace view bd.lead_view with (security_invoker = true) as
select
  l.*,
  coalesce(p.name, l.title) as display_name,
  coalesce(p.technology, l.technology) as subject_technology,
  coalesce(p.state, l.state) as subject_state,
  coalesce(p.fips, l.jurisdiction_fips) as subject_fips,
  coalesce(p.stage, l.subject_stage) as project_stage,
  coalesce(p.jurisdiction_name, l.jurisdiction_name) as place_name,
  j.name as county_name,
  j.risk_tier,
  j.restriction_type,
  p.mw_ac, p.mw_storage, p.acres, p.iso, p.queue_id, p.queue_entered_at,
  d.name as developer_name,
  d.parent_name as developer_parent,
  sig.last_signal_at,
  sig.signal_count,
  sig.latest_headline,
  sig.latest_url
from bd.leads l
left join bd.projects p on p.id = l.project_id
left join bd.jurisdictions j on j.fips = coalesce(p.fips, l.jurisdiction_fips)
left join bd.developers d on d.id = coalesce(p.developer_id, l.developer_id)
left join lateral (
  select max(s.observed_at) as last_signal_at,
         count(*) as signal_count,
         (array_agg(s.headline order by s.observed_at desc))[1] as latest_headline,
         (array_agg(s.url order by s.observed_at desc))[1] as latest_url
  -- two index lookups instead of an OR, which would scan signals once per lead
  from (
    select s1.observed_at, s1.headline, s1.url from bd.signals s1
     where s1.project_id = l.project_id and not s1.is_noise
    union all
    select s2.observed_at, s2.headline, s2.url from bd.signals s2
     where s2.lead_id = l.id and s2.project_id is distinct from l.project_id and not s2.is_noise
  ) s
) sig on true
where not coalesce(p.is_noise, false);

grant select on bd.lead_view to service_role;

-- Functions: service_role only.
revoke execute on all functions in schema bd from public;
grant execute on all functions in schema bd to service_role;
