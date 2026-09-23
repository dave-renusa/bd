-- BD Radar: Greenlight Weekly ingestion.
-- A weekly Claude routine reads the newsletter from Gmail, extracts each item
-- into JSON, and calls this function through the Supabase connector.
--
-- p_entries: array of {
--   title, applicant, place, state (2-letter, null for federal),
--   county (county name when known, e.g. "San Bernardino County"),
--   date (YYYY-MM-DD), status (APPROVED | ACTIVE | DELAYED | DENIED | RESTRICTED),
--   tech_tag (as printed), technology (bd.technology or null),
--   kind ('project' | 'jurisdiction'),
--   stage (bd.project_stage, optional), signal_type (bd.signal_type, optional),
--   mw, acres, outcome }
-- Items already on file (same title) get a new signal instead of a duplicate
-- record, and a signal is skipped when the same item already has one for that
-- date (so the hand-loaded Issue #25 seeds are not doubled).

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
      when 'RESTRICTED' then 'moratorium_blocked' else 'hearing' end::bd.project_stage);
    v_sig := coalesce(r.signal_type, case v_status
      when 'APPROVED' then 'approved' when 'DENIED' then 'denied' when 'DELAYED' then 'tabled'
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
      -- Fallback: same county and technology with a signal on the same date.
      if v_proj is null and v_fips is not null then
        select p.id into v_proj from bd.projects p
         where p.fips = v_fips
           and (p.technology = 'other' or bd.tech_overlap(p.technology, coalesce(r.technology, 'other')))
           and exists (select 1 from bd.signals s where s.project_id = p.id and s.observed_at::date = v_date::date)
         limit 1;
      end if;
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
        where id = v_proj and not v_keep
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
          or (kind = 'jurisdiction' and v_fips is not null and jurisdiction_fips = v_fips
              and subject_stage_at::date = v_date::date)
       limit 1;
      if v_lead is null then
        insert into bd.leads (kind, title, external_key, jurisdiction_fips, jurisdiction_name, technology,
                              state, subject_stage, subject_stage_at, stage, created_by)
        values ('jurisdiction', trim(r.title), 'greenlight:' || v_slug, v_fips, r.place, r.technology,
                v_state, v_stage, v_date, 'Signal', 'greenlight:' || p_issue)
        returning id into v_lead;
        n_new_lead := n_new_lead + 1;
      else
        update bd.leads set subject_stage = v_stage, subject_stage_at = v_date
         where id = v_lead and not v_keep and subject_stage is distinct from v_stage;
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

-- One-time corrections to the Issue #25 seeds now that the newsletter text is
-- available: exact dates for two items and the newsletter's name for Monolith.
update bd.projects set name = 'Monolith / Crusoe Hallam data center', stage_changed_at = '2026-09-16', last_signal_at = '2026-09-16'
 where external_key = 'manual:greenlight25:monolith-crusoe-hallam';
update bd.projects set stage_changed_at = '2026-09-16', last_signal_at = '2026-09-16'
 where external_key = 'manual:greenlight25:project-bluestem';
update bd.signals set observed_at = '2026-09-16'
 where dedupe_key in ('manual:greenlight25:monolith-crusoe-hallam', 'manual:greenlight25:project-bluestem');
update bd.leads l set title = p.name from bd.projects p
 where l.project_id = p.id and p.external_key = 'manual:greenlight25:monolith-crusoe-hallam';

revoke execute on function bd.ingest_greenlight(integer, date, text, jsonb) from public;
grant execute on function bd.ingest_greenlight(integer, date, text, jsonb) to service_role;
