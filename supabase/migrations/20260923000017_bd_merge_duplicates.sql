-- BD Radar: merge duplicate projects.
-- PJM lists one project under several queue requests, and the same project
-- can arrive from PJM, Sabin and Greenlight. Projects with the same name
-- (case, spacing and a trailing "project" ignored), state and county are one
-- project. The most informative record represents the group (Greenlight or
-- manual, then Sabin, then the queue; among queue rows the active, newest
-- request). The others keep their feed keys, so the feeds can still update
-- them, but point at the representative through merged_into, hand it their
-- signals, and carry no lead. run_scoring() re-runs the merge after every
-- feed, so new duplicates fold in on their own.

alter table bd.projects add column if not exists merged_into uuid references bd.projects (id) on delete set null;
create index if not exists projects_merged_into_idx on bd.projects (merged_into) where merged_into is not null;

create or replace function bd.project_name_key(p_name text) returns text
language sql immutable as $$
  select regexp_replace(lower(regexp_replace(trim(p_name), '\s+', ' ', 'g')), ' project$', '')
$$;

create or replace function bd.merge_duplicate_projects() returns integer
language plpgsql set search_path = bd, pg_temp as $$
declare n int;
begin
  create temp table _grp on commit drop as
  select id, first_value(id) over w as keep, count(*) over (partition by k) as size
  from (
    select p.*, (bd.project_name_key(p.name), p.state, p.fips)::text as k,
           case when p.external_key like 'greenlight:%' or p.external_key like 'manual:%' then 0
                when p.external_key like 'sabin:%' then 1 else 2 end as src_rank
    from bd.projects p
    where not p.is_noise and p.fips is not null
  ) x
  window w as (partition by k order by src_rank, (stage = 'withdrawn'), queue_entered_at desc nulls last, created_at, id);

  -- Point duplicates at their representative; clear it everywhere else.
  update bd.projects p set merged_into = case when g.size > 1 and g.id <> g.keep then g.keep end
  from _grp g
  where g.id = p.id and p.merged_into is distinct from (case when g.size > 1 and g.id <> g.keep then g.keep end);
  get diagnostics n = row_count;

  -- The representative takes its duplicates' signals and fills gaps in size.
  update bd.signals s set project_id = g.keep
  from _grp g where g.size > 1 and g.id <> g.keep and s.project_id = g.id;
  update bd.projects p set
    mw_ac = coalesce(p.mw_ac, d.mw_ac), mw_storage = coalesce(p.mw_storage, d.mw_storage),
    acres = coalesce(p.acres, d.acres), developer_id = coalesce(p.developer_id, d.developer_id),
    last_signal_at = greatest(p.last_signal_at, d.last_signal_at)
  from (select g.keep, max(q.mw_ac) mw_ac, max(q.mw_storage) mw_storage, max(q.acres) acres,
               (array_agg(q.developer_id) filter (where q.developer_id is not null))[1] developer_id,
               max(q.last_signal_at) last_signal_at
        from _grp g join bd.projects q on q.id = g.id
        where g.size > 1 and g.id <> g.keep group by g.keep) d
  where p.id = d.keep;

  -- One lead per group. Keep the one someone has worked (owner, stage, notes,
  -- next action or snooze), else the representative's, else the oldest; move
  -- it onto the representative and drop the rest.
  create temp table _lead on commit drop as
  select l.id, g.keep,
         row_number() over (partition by g.keep order by
           (l.owner is not null or l.stage not in ('New', 'Watch') or l.next_action is not null
            or l.snoozed_until is not null or exists (select 1 from bd.lead_notes nt where nt.lead_id = l.id)) desc,
           (l.project_id = g.keep) desc, l.created_at, l.id) as rn
  from bd.leads l join _grp g on g.id = l.project_id
  where l.kind = 'project' and g.size > 1;
  delete from bd.leads l using _lead x where x.id = l.id and x.rn > 1;
  update bd.leads l set project_id = x.keep, title = p.name
  from _lead x join bd.projects p on p.id = x.keep
  where x.id = l.id and x.rn = 1 and l.project_id is distinct from x.keep;

  drop table _grp; drop table _lead;
  return n;
end $$;

create or replace function bd.ensure_project_leads() returns integer
language plpgsql set search_path = bd, pg_temp as $$
declare n int;
begin
  insert into bd.leads (kind, title, project_id, developer_id, jurisdiction_fips, technology, state,
                        stage, created_by)
  select 'project', p.name, p.id, p.developer_id, p.fips, p.technology, p.state,
         case when p.stage = 'approved' then 'Watch'::bd.lead_stage else 'New'::bd.lead_stage end,
         'scoring'
  from bd.projects p
  where not p.is_noise and p.merged_into is null
    and not exists (select 1 from bd.leads l where l.kind = 'project' and l.project_id = p.id);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function bd.run_scoring() returns jsonb
language plpgsql set search_path = bd, pg_temp as $$
declare v_created int; v_scored int; v_qualified int;
begin
  perform bd.refresh_jurisdiction_risk();
  perform bd.merge_duplicate_projects();
  v_created := bd.ensure_project_leads();
  v_scored := bd.rescore_leads();
  select count(*) into v_qualified from bd.leads where qualified_at = now();
  return jsonb_build_object('leads_created', v_created, 'leads_changed', v_scored,
                            'newly_qualified', v_qualified);
end $$;

create or replace function bd.ingest_greenlight(p_issue integer, p_issue_date date, p_url text, p_entries jsonb)
returns jsonb
language plpgsql set search_path = bd, pg_temp as $$
declare
  r record;
  v_slug text; v_state text; v_fips text; v_stage bd.project_stage; v_sig bd.signal_type;
  v_date timestamptz; v_dev uuid; v_proj uuid; v_lead uuid; v_status text;
  n_new_proj int := 0; n_new_lead int := 0; n_signals int := 0; n_dup int := 0; n_updated int := 0;
  v_rows int; v_keep boolean;
begin
  for r in
    select * from jsonb_to_recordset(p_entries) as x(
      title text, applicant text, place text, state text, county text, date date,
      status text, tech_tag text, technology bd.technology, kind text,
      stage bd.project_stage, signal_type bd.signal_type, mw numeric, acres numeric, outcome text)
  loop
    continue when nullif(trim(r.title), '') is null;
    v_slug := trim(both '-' from regexp_replace(lower(r.title), '[^a-z0-9]+', '-', 'g'));
    v_state := nullif(upper(trim(r.state)), '');
    v_status := upper(coalesce(r.status, ''));
    v_date := coalesce(r.date, p_issue_date)::timestamptz;
    v_fips := case
      when v_state is null then null
      when nullif(trim(r.county), '') is not null then bd.match_county(v_state, r.county)
      when r.kind = 'jurisdiction' and r.place ilike '%statewide%'
        then (select fips from bd.jurisdictions where kind = 'state' and state = v_state)
      else null end;

    v_stage := coalesce(r.stage, case v_status
      when 'APPROVED' then 'approved' when 'DENIED' then 'denied' when 'DELAYED' then 'tabled'
      when 'WITHDRAWN' then 'withdrawn'
      when 'RESTRICTED' then 'moratorium_blocked' else 'hearing' end::bd.project_stage);
    v_sig := coalesce(r.signal_type, case v_status
      when 'APPROVED' then 'approved' when 'DENIED' then 'denied' when 'DELAYED' then 'tabled'
      when 'WITHDRAWN' then 'withdrawn'
      when 'RESTRICTED' then (case when r.outcome ~* 'moratori|pause|prohibit' then 'moratorium' else 'restriction_enacted' end)
      else 'hearing_scheduled' end::bd.signal_type);

    v_proj := null; v_lead := null; v_dev := null;
    -- ACTIVE is vague, so it never overwrites a more specific stage already on file.
    v_keep := v_status = 'ACTIVE' and r.stage is null;

    if v_state is not null and coalesce(r.kind, 'project') = 'project' then
      select id into v_proj from bd.projects
       where external_key = 'greenlight:' || v_slug
          or (lower(name) = lower(trim(r.title)) and (state is null or state = v_state))
       order by (external_key = 'greenlight:' || v_slug) desc nulls last
       limit 1;
      -- Fallback for hand-entered items (external_key 'manual:...') whose names differ
      -- from the newsletter's: same county and technology with a signal on the same date.
      if v_proj is null and v_fips is not null then
        select p.id into v_proj from bd.projects p
         where p.fips = v_fips and p.external_key like 'manual:%'
           and (p.technology = 'other' or bd.tech_overlap(p.technology, coalesce(r.technology, 'other')))
           and exists (select 1 from bd.signals s where s.project_id = p.id and s.observed_at::date = v_date::date)
         limit 1;
      end if;
      -- A merged duplicate stands for the project it was merged into.
      select coalesce(merged_into, id) into v_proj from bd.projects where id = v_proj;
      if v_proj is null then
        v_dev := bd.upsert_developer(split_part(r.applicant, ' / ', 1), r.technology);
        if position(' / ' in coalesce(r.applicant, '')) > 0 then
          update bd.developers set parent_name = split_part(r.applicant, ' / ', 2)
           where id = v_dev and parent_name is null;
        end if;
        insert into bd.projects (name, developer_id, developer_raw, technology, mw_ac, acres, state, county,
                                 fips, jurisdiction_name, stage, stage_changed_at, status_source,
                                 external_key, last_signal_at, created_by)
        values (trim(r.title), v_dev, r.applicant, coalesce(r.technology, 'other'), r.mw, r.acres, v_state,
                (select county from bd.jurisdictions where fips = v_fips), v_fips, r.place, v_stage, v_date,
                v_status, 'greenlight:' || v_slug, v_date, 'greenlight:' || p_issue)
        returning id into v_proj;
        n_new_proj := n_new_proj + 1;
      else
        update bd.projects set
          stage = v_stage,
          stage_changed_at = case when stage is distinct from v_stage then v_date else stage_changed_at end,
          status_source = v_status,
          mw_ac = coalesce(mw_ac, r.mw), acres = coalesce(acres, r.acres),
          last_signal_at = greatest(coalesce(last_signal_at, v_date), v_date)
        where id = v_proj and not v_keep and v_date >= stage_changed_at
          and (stage is distinct from v_stage or status_source is distinct from v_status);
        get diagnostics v_rows = row_count; n_updated := n_updated + v_rows;
        -- Fill gaps the newsletter answers (e.g. a technology first recorded as 'other').
        update bd.projects set
          technology = case when technology = 'other' and r.technology is not null then r.technology else technology end,
          mw_ac = coalesce(mw_ac, r.mw), acres = coalesce(acres, r.acres),
          fips = coalesce(fips, v_fips)
        where id = v_proj
          and ((technology = 'other' and r.technology is not null and r.technology <> 'other')
               or (mw_ac is null and r.mw is not null) or (acres is null and r.acres is not null)
               or (fips is null and v_fips is not null));
        select developer_id into v_dev from bd.projects where id = v_proj;
      end if;

    elsif v_state is not null then
      select id into v_lead from bd.leads
       where external_key = 'greenlight:' || v_slug
          or (kind = 'jurisdiction' and lower(title) = lower(trim(r.title)))
          or (kind = 'jurisdiction' and external_key like 'manual:%' and v_fips is not null
              and jurisdiction_fips = v_fips and subject_stage_at::date = v_date::date)
       limit 1;
      if v_lead is null then
        insert into bd.leads (kind, title, external_key, jurisdiction_fips, jurisdiction_name, technology,
                              state, subject_stage, subject_stage_at, stage, created_by)
        values ('jurisdiction', trim(r.title), 'greenlight:' || v_slug, v_fips, r.place, r.technology,
                v_state, v_stage, v_date, 'New', 'greenlight:' || p_issue)
        returning id into v_lead;
        n_new_lead := n_new_lead + 1;
      else
        update bd.leads set subject_stage = v_stage, subject_stage_at = v_date
         where id = v_lead and not v_keep and subject_stage is distinct from v_stage
           and v_date >= coalesce(subject_stage_at, '-infinity'::timestamptz);
        get diagnostics v_rows = row_count; n_updated := n_updated + v_rows;
      end if;
    end if;

    -- Skip when this item already has a signal for the same date (e.g. the Issue #25 seeds).
    if exists (select 1 from bd.signals s
               where s.observed_at::date = v_date::date
                 and ((v_proj is not null and s.project_id = v_proj) or (v_lead is not null and s.lead_id = v_lead))) then
      n_dup := n_dup + 1;
      continue;
    end if;

    insert into bd.signals (project_id, developer_id, lead_id, jurisdiction_fips, source, signal_type,
                            headline, detail, url, observed_at, raw, dedupe_key, created_by)
    values (v_proj, v_dev, v_lead, v_fips, 'greenlight', v_sig,
            left(format('%s: %s', trim(r.title), coalesce(r.outcome, v_status)), 300),
            format('Greenlight Weekly #%s. %s. %s, %s. Tag: %s.', p_issue, v_status,
                   coalesce(r.applicant, 'applicant not listed'), coalesce(r.place, 'place not listed'),
                   coalesce(r.tech_tag, 'none')),
            p_url, v_date,
            jsonb_build_object('issue', p_issue, 'issue_date', p_issue_date, 'entry', to_jsonb(r)),
            'greenlight:' || p_issue || ':' || v_slug, 'greenlight:' || p_issue)
    on conflict (dedupe_key) do nothing;
    get diagnostics v_rows = row_count;
    if v_rows = 0 then n_dup := n_dup + 1; else n_signals := n_signals + v_rows; end if;
  end loop;

  perform bd.record_source_run('greenlight', 'ok', jsonb_array_length(p_entries), null,
    jsonb_build_object('issue', p_issue, 'new_projects', n_new_proj, 'new_jurisdiction_leads', n_new_lead,
                       'signals', n_signals, 'duplicates_skipped', n_dup, 'updated', n_updated), null);

  return jsonb_build_object('issue', p_issue, 'entries', jsonb_array_length(p_entries),
    'new_projects', n_new_proj, 'new_jurisdiction_leads', n_new_lead, 'signals', n_signals,
    'duplicates_skipped', n_dup, 'updated', n_updated, 'scoring', bd.run_scoring());
end $$;

select bd.run_scoring();
