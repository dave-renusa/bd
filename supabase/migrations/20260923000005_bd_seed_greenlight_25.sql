-- BD Radar: day-one seed leads from Greenlight Weekly Issue #25 (Sep 23, 2026).
-- Loaded as manual signals. Idempotent: keyed on external_key and dedupe_key.
-- Where the handoff did not state a technology or stage, the row says so in
-- `detail` and uses 'other' so the lead does not score on a guess.

do $$
declare
  r jsonb;
  v_dev uuid;
  v_proj uuid;
  v_lead uuid;
  v_stage_at timestamptz;
begin
  for r in select * from jsonb_array_elements($json$[
    {"key": "crossroads-tech-campus", "kind": "project",
     "title": "Crossroads Technology Campus", "developer": "RCK Digital Crossroads LLC", "parent": "Amazon Web Services",
     "tech": "data_center", "state": "VA", "fips": "51177", "acres": 555,
     "stage": "filed", "date": "2026-09-16", "signal_type": "news",
     "headline": "Spotsylvania PC recommended approval 4-2 for Crossroads Technology Campus; Board vote pending",
     "detail": "~555 acres. Planning Commission recommended approval 4-2 on Sep 16. Board of Supervisors vote pending."},

    {"key": "dulles-technology-park", "kind": "project",
     "title": "Dulles Technology Park", "developer": "B.F. Saul Company",
     "tech": "data_center", "state": "VA", "fips": "51107", "acres": 37,
     "stage": "contested", "date": "2026-09-17", "signal_type": "news",
     "headline": "Loudoun PC recommended denial 5-4 on Dulles Technology Park rezoning",
     "detail": "~37-acre rezoning. Planning Commission recommended denial 5-4 on Sep 17."},

    {"key": "loudoun-dc-pause", "kind": "jurisdiction", "attach_to": "dulles-technology-park",
     "title": "Loudoun County 12-month pause on data center and substation final votes",
     "tech": "data_center", "state": "VA", "fips": "51107",
     "stage": "moratorium_blocked", "date": "2026-09-15", "signal_type": "moratorium",
     "headline": "Loudoun Board approved a 12-month pause on final votes for qualifying data center and substation applications",
     "detail": "Board action Sep 15. Treated as a moratorium for scoring."},

    {"key": "nextera-transmission-frederick", "kind": "project",
     "title": "NextEra Energy Transmission Virginia facilities", "developer": "NextEra Energy Transmission",
     "tech": "transmission", "state": "VA", "fips": "51069",
     "stage": "state_prefiling", "date": "2026-09-16", "signal_type": "hearing_scheduled",
     "headline": "SCC public witness hearing on NextEra Energy Transmission Virginia facilities (Frederick County)",
     "detail": "State Corporation Commission public witness hearing Sep 16."},

    {"key": "mnz07-wellington", "kind": "project",
     "title": "MNZ07 Wellington campus", "developer": "Microsoft",
     "tech": "data_center", "state": "VA", "fips": "51153", "acres": 123,
     "stage": "filed", "date": "2026-09-16", "signal_type": "permit_filed",
     "headline": "USACE wetlands permit under review for Microsoft MNZ07 Wellington campus",
     "detail": "Two buildings on ~123 acres. USACE wetlands permit under review as of Sep 16."},

    {"key": "900-conshohocken-road", "kind": "project",
     "title": "900 Conshohocken Road data center", "developer": "MLP Ventures",
     "tech": "data_center", "state": "PA", "fips": "42091", "place": "Plymouth Township",
     "stage": "tabled", "date": "2026-09-17", "signal_type": "tabled",
     "headline": "Plymouth Township zoning hearing on 900 Conshohocken Road canceled over Sunshine Act posting defect",
     "detail": "Hearing canceled Sep 17 because of a Sunshine Act posting defect."},

    {"key": "im-pittsburgh-variances", "kind": "project",
     "title": "IM Pittsburgh generator variances", "developer": "IM Pittsburgh LLC",
     "tech": "other", "state": "PA", "fips": "42003", "place": "Wilkinsburg",
     "stage": "tabled", "date": "2026-09-17", "signal_type": "tabled",
     "headline": "Wilkinsburg hearing on IM Pittsburgh generator variances continued",
     "detail": "Hearing continued Sep 17. Technology not stated in the handoff; confirm and update."},

    {"key": "scott-county-va-dc-ordinance", "kind": "jurisdiction",
     "title": "Scott County VA data center zoning ordinance",
     "tech": "data_center", "state": "VA", "fips": "51169",
     "stage": "tabled", "date": "2026-09-14", "signal_type": "tabled",
     "headline": "Scott County VA Planning Commission tabled data center zoning ordinance",
     "detail": "PC tabled Sep 14."},

    {"key": "statesville-dc-moratorium", "kind": "jurisdiction",
     "title": "Statesville NC 180-day data center moratorium",
     "tech": "data_center", "state": "NC", "fips": "37097", "place": "Statesville",
     "stage": "moratorium_blocked", "date": "2026-09-14", "signal_type": "moratorium",
     "headline": "Statesville NC adopted a 180-day data center moratorium",
     "detail": "Sep 14. Statesville is in Iredell County."},

    {"key": "vance-county-dc-moratorium", "kind": "jurisdiction",
     "title": "Vance County NC 60-day data center moratorium",
     "tech": "data_center", "state": "NC", "fips": "37181",
     "stage": "moratorium_blocked", "date": "2026-09-14", "signal_type": "moratorium",
     "headline": "Vance County NC adopted a 60-day data center moratorium",
     "detail": "Sep 14."},

    {"key": "project-delta-stokes", "kind": "project",
     "title": "Project Delta", "developer": "DFC Stokes LLC", "parent": "Engineered Land Solutions",
     "tech": "other", "state": "NC", "fips": "37169", "acres": 1849,
     "stage": "approved", "date": "2026-09-14", "signal_type": "approved",
     "headline": "Stokes County approved conditional rezoning for Project Delta (~1,849 acres)",
     "detail": "Conditional rezoning approved Sep 14. Watch bucket. Technology not stated in the handoff; confirm and update."},

    {"key": "rabro-drive-bess", "kind": "project",
     "title": "Rabro Drive BESS", "developer": "Key Capture Energy",
     "tech": "bess", "state": "NY", "fips": "36103", "place": "Islip", "mw": 79,
     "stage": "moratorium_blocked", "date": "2026-09-15", "signal_type": "restriction_enacted",
     "headline": "Islip NY large-scale BESS prohibition blocks Key Capture Energy's 79 MW Rabro Drive project",
     "detail": "Sep 15. Credential: RenUSA's Marathon Power BESS work in Huntington NY.",
     "next_action": "Lead with the Marathon Power Huntington BESS credential."},

    {"key": "dunkirk-bess-moratorium", "kind": "jurisdiction",
     "title": "Dunkirk NY BESS moratorium extension",
     "tech": "bess", "state": "NY", "fips": "36013", "place": "Dunkirk",
     "stage": "moratorium_blocked", "date": "2026-09-15", "signal_type": "moratorium",
     "headline": "Dunkirk NY extended its BESS moratorium",
     "detail": "Sep 15. Dunkirk is in Chautauqua County. Credential: Marathon Power BESS work in Huntington NY."},

    {"key": "huron-county-mi-ordinance", "kind": "jurisdiction",
     "title": "Huron County MI solar and BESS ordinance",
     "tech": "solar_bess", "state": "MI", "fips": "26063",
     "stage": "hearing", "date": "2026-09-16", "signal_type": "hearing_scheduled",
     "headline": "Huron County MI deliberating solar and BESS ordinance",
     "detail": "Ordinance deliberations Sep 16."},

    {"key": "gallatin-dc-moratorium", "kind": "jurisdiction",
     "title": "Gallatin TN data center moratorium",
     "tech": "data_center", "state": "TN", "fips": "47165", "place": "Gallatin",
     "stage": "hearing", "date": "2026-09-15", "signal_type": "hearing_scheduled",
     "headline": "Gallatin TN data center moratorium advanced on first reading",
     "detail": "Passed first reading Sep 15; not yet adopted. Gallatin is in Sumner County."},

    {"key": "project-bluestem", "kind": "project", "watch": true,
     "title": "Project Bluestem", "developer": "Cloverleaf Infrastructure",
     "tech": "data_center", "state": "KS", "fips": "20103", "place": "Tonganoxie",
     "stage": "filed", "date": "2026-09-15", "signal_type": "news",
     "headline": "Project Bluestem (~1.2 GW, Cloverleaf Infrastructure) in Tonganoxie KS",
     "detail": "Outside the East footprint: flag for other team heads. Stage not stated in the handoff; 'filed' is a placeholder. Date is approximate (Issue #25 week).",
     "next_action": "Flag for other team heads."},

    {"key": "monolith-crusoe-hallam", "kind": "project", "watch": true,
     "title": "Monolith / Crusoe Hallam NE", "developer": "Crusoe",
     "tech": "data_center", "state": "NE", "fips": "31109", "place": "Hallam",
     "stage": "filed", "date": "2026-09-15", "signal_type": "news",
     "headline": "Special use permit recommended for Monolith / Crusoe data center in Hallam NE (~35 MW)",
     "detail": "Outside the East footprint: flag for other team heads. Date is approximate (Issue #25 week).",
     "next_action": "Flag for other team heads."},

    {"key": "clackamas-moratorium-hearing", "kind": "jurisdiction", "watch": true,
     "title": "Clackamas County OR moratorium hearing",
     "state": "OR", "fips": "41005",
     "stage": "hearing", "date": "2026-09-15", "signal_type": "hearing_scheduled",
     "headline": "Clackamas County OR moratorium hearing",
     "detail": "Outside the East footprint: flag for other team heads. Moratorium subject not stated in the handoff. Date is approximate (Issue #25 week).",
     "next_action": "Flag for other team heads."}
  ]$json$::jsonb)
  loop
    v_stage_at := (r->>'date')::timestamptz;
    v_dev := null; v_proj := null; v_lead := null;

    if r ? 'developer' then
      v_dev := bd.upsert_developer(r->>'developer', nullif(r->>'tech', '')::bd.technology);
      if r ? 'parent' then
        update bd.developers set parent_name = r->>'parent' where id = v_dev and parent_name is null;
      end if;
    end if;

    if r->>'kind' = 'project' then
      insert into bd.projects (name, developer_id, developer_raw, technology, mw_ac, acres, state,
                               county, fips, jurisdiction_name, stage, stage_changed_at,
                               external_key, last_signal_at, created_by)
      select r->>'title', v_dev, r->>'developer', (r->>'tech')::bd.technology,
             (r->>'mw')::numeric, (r->>'acres')::numeric, r->>'state', j.county, j.fips,
             r->>'place', (r->>'stage')::bd.project_stage, v_stage_at,
             'manual:greenlight25:' || (r->>'key'), v_stage_at, 'seed:greenlight25'
      from bd.jurisdictions j where j.fips = r->>'fips'
      on conflict (external_key) do nothing;
      select id into v_proj from bd.projects where external_key = 'manual:greenlight25:' || (r->>'key');

      insert into bd.leads (kind, title, project_id, developer_id, jurisdiction_fips, technology, state,
                            stage, next_action, created_by)
      values ('project', r->>'title', v_proj, v_dev, r->>'fips', (r->>'tech')::bd.technology, r->>'state',
              case when r->>'stage' = 'approved' or (r->>'watch')::boolean then 'Watch' else 'Signal' end::bd.lead_stage,
              r->>'next_action', 'seed:greenlight25')
      on conflict (project_id) where kind = 'project' do nothing;
      select id into v_lead from bd.leads where kind = 'project' and project_id = v_proj;
    else
      insert into bd.leads (kind, title, external_key, jurisdiction_fips, jurisdiction_name, technology,
                            state, subject_stage, subject_stage_at, stage, next_action, created_by)
      values ('jurisdiction', r->>'title', 'manual:greenlight25:' || (r->>'key'), r->>'fips', r->>'place',
              nullif(r->>'tech', '')::bd.technology, r->>'state', (r->>'stage')::bd.project_stage,
              v_stage_at,
              case when (r->>'watch')::boolean then 'Watch' else 'Signal' end::bd.lead_stage,
              r->>'next_action', 'seed:greenlight25')
      on conflict (external_key) do nothing;
      select id into v_lead from bd.leads where external_key = 'manual:greenlight25:' || (r->>'key');
    end if;

    -- A jurisdiction signal can also be attached to a project (Loudoun pause -> Dulles).
    if r ? 'attach_to' then
      select id into v_proj from bd.projects where external_key = 'manual:greenlight25:' || (r->>'attach_to');
    end if;

    insert into bd.signals (project_id, developer_id, lead_id, jurisdiction_fips, source, signal_type,
                            headline, detail, observed_at, raw, dedupe_key, created_by)
    values (v_proj, v_dev, v_lead, r->>'fips', 'manual', (r->>'signal_type')::bd.signal_type,
            r->>'headline', r->>'detail', v_stage_at,
            jsonb_build_object('origin', 'Greenlight Weekly Issue #25 (Sep 23, 2026)', 'seed', r),
            'manual:greenlight25:' || (r->>'key'), 'seed:greenlight25')
    on conflict (dedupe_key) do nothing;
  end loop;
end $$;

select bd.run_scoring();
