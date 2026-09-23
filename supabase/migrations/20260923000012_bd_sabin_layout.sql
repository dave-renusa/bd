-- BD Radar: Sabin file layout fix.
-- The live Sabin files name the project "Title" and the technology "Type",
-- which the feed did not read, so contested projects landed as "Contested
-- project in X County" with technology "other". The feed now reads those
-- columns and keys rows on Sabin's own ID. Because the keys change, this
-- clears the Sabin records so the next Sabin run rebuilds them. No Sabin lead
-- had an owner, note, snooze or hand-set stage.
--
-- The loader now also refreshes name, technology, size and place on re-runs,
-- and a status change takes the file's event date instead of today.

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
      name = excluded.name,
      technology = excluded.technology,
      mw_ac = coalesce(excluded.mw_ac, bd.projects.mw_ac),
      county = excluded.county,
      fips = excluded.fips,
      jurisdiction_name = excluded.jurisdiction_name,
      stage = case when bd.projects.status_source is distinct from excluded.status_source
                   then excluded.stage else bd.projects.stage end,
      stage_changed_at = case when bd.projects.status_source is distinct from excluded.status_source
                   then greatest(excluded.stage_changed_at, bd.projects.stage_changed_at)
                   else bd.projects.stage_changed_at end,
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

delete from bd.signals where source in ('sabin_contested', 'sabin_restriction');
delete from bd.projects where external_key like 'sabin:%';  -- cascades to their leads
update bd.jurisdictions set
  has_restriction = false, restriction_type = null, restriction_summary = null,
  restriction_effective = null, has_moratorium = false, moratorium_until = null
where has_restriction or has_moratorium;
update bd.jurisdictions set contested_project_count = 0 where contested_project_count > 0;
select bd.refresh_jurisdiction_risk();
