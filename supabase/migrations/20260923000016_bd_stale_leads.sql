-- BD Radar: weed out stale leads.
-- A lead with no real-world activity in stale_months (default 24) is capped
-- at stale_cap (default 30), below the default 50 view, and the score says
-- why. "Activity" is the permitting date on file or the newest dated signal
-- (Greenlight, manual, opposition); Sabin and queue downloads do not count
-- because they carry the download date. The breakdown also reports
-- last_activity so the site can show it.

insert into bd.settings (key, value, description) values
  ('stale_months', '24', 'Leads with no activity for this many months are capped at stale_cap.'),
  ('stale_cap',    '30', 'Highest score a stale lead can have. Keep it under signal_threshold to hide stale leads by default.')
on conflict (key) do nothing;

update bd.settings set description = 'Score at which a lead alerts (stamps qualified_at).'
where key = 'qualify_threshold';

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
  v_last timestamptz; v_total int;
  v_stale_months int := bd.setting_num('stale_months', 24);
  v_stale_cap int := bd.setting_num('stale_cap', 30);
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

  -- Staleness ---------------------------------------------------------------
  -- Last real-world activity: the permitting date on file, or the newest dated
  -- signal. Sabin and queue signals carry the download date, not an event
  -- date, so they do not count. Queue projects are already aged by the queue rule.
  v_total := greatest(0, least(100, fit + stg + pain + acc + comp));
  select greatest(v_stage_at, max(s.observed_at)) into v_last
  from bd.signals s
  where not s.is_noise
    and s.source not in ('sabin_contested', 'sabin_restriction', 'pjm_queue', 'miso_queue', 'nyiso_queue',
                         'isone_queue', 'spp_queue', 'ercot_gis', 'duke_queue', 'dominion_queue',
                         'southern_queue', 'tva_queue')
    and (s.project_id = l.project_id or s.lead_id = l.id);
  v_last := coalesce(v_last, v_stage_at);
  if v_stage is distinct from 'queue' and v_last < now() - make_interval(months => v_stale_months)
     and v_total > v_stale_cap then
    reasons := reasons || jsonb_build_object('factor', 'stage', 'key', 'stale', 'points', v_stale_cap - v_total,
      'label', format('No activity in %s+ months, score capped at %s', v_stale_months, v_stale_cap),
      'detail', 'last activity ' || to_char(v_last, 'Mon YYYY'));
    v_total := v_stale_cap;
  end if;

  return jsonb_build_object(
    'total', v_total,
    'fit', fit, 'stage', stg, 'pain', pain, 'access', acc, 'competition', comp,
    'last_activity', v_last::date,
    'stale', v_total = v_stale_cap and v_last < now() - make_interval(months => v_stale_months),
    'reasons', reasons);
end $$;

-- Search: hide Closed leads unless the stage filter or p_include_closed asks for them.
drop function if exists bd.search_leads(text, text, text, text, text, text, int, int);
create or replace function bd.search_leads(
  p_q text default null,
  p_state text default null,
  p_tech text default null,
  p_kind text default null,
  p_stage text default null,
  p_owner text default null,
  p_min int default 0,
  p_limit int default 500,
  p_include_closed boolean default false
) returns setof bd.lead_view
language plpgsql stable set search_path = bd, pg_temp as $$
declare
  v_words text[];
begin
  -- Keywords, with LIKE wildcards escaped so "100%" or "a_b" match literally.
  select coalesce(array_agg('%' || replace(replace(replace(w, '\', '\\'), '%', '\%'), '_', '\_') || '%'), '{}')
    into v_words
  from unnest(regexp_split_to_array(trim(coalesce(p_q, '')), '\s+')) w
  where w <> '';

  return query
  select v.*
  from bd.lead_view v
  where (p_state is null or v.subject_state = upper(p_state))
    and (p_tech is null or v.subject_technology::text = p_tech)
    and (p_kind is null or v.kind::text = p_kind)
    and (p_stage is null or v.stage::text = p_stage)
    -- Closed leads stay out of the way unless asked for
    and (p_stage is not null or p_include_closed or v.stage <> 'Closed')
    and (p_owner is null or (p_owner = '_none' and v.owner is null) or v.owner = p_owner)
    and v.score >= coalesce(p_min, 0)
    and (cardinality(v_words) = 0 or (
      select bool_and(d.doc ilike w)
      from (
        select concat_ws(' ', v.display_name, v.developer_name, v.developer_parent, v.place_name,
                         v.county_name, v.subject_state, v.restriction_type, v.queue_id, v.why_now,
                         (select string_agg(concat_ws(' ', s.headline, s.detail), ' ')
                            from (select s1.headline, s1.detail from bd.signals s1
                                   where s1.project_id = v.project_id and not s1.is_noise
                                  union all
                                  select s2.headline, s2.detail from bd.signals s2
                                   where s2.lead_id = v.id and s2.project_id is distinct from v.project_id
                                     and not s2.is_noise) s)) as doc
      ) d, unnest(v_words) w
    ))
  order by v.score desc, v.last_signal_at desc nulls last
  limit least(coalesce(p_limit, 500), 1000);
end $$;

revoke all on function bd.search_leads(text, text, text, text, text, text, int, int, boolean) from public;
grant execute on function bd.search_leads(text, text, text, text, text, text, int, int, boolean) to service_role;

select bd.run_scoring();
