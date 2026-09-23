# Handoff: RenUSA BD Radar (business development opportunity system)

**Date:** 2026-09-23
**Original thread purpose:** Design a system that finds early-stage solar, wind, BESS and data center projects that need RenUSA community engagement support, and turns them into a scored, owned BD pipeline.
**Status:** Design agreed. Ready for build in Claude Code. No code written yet.

## Confirmed facts (resolved after the handoff was written)

- Repo: dave-renusa/bd.
- Supabase: project ref `csxvtewzlhigrzvpxtvf` ("BD Database", us-east-1, https://csxvtewzlhigrzvpxtvf.supabase.co). Reused project: `public.support_messages` (12 rows) is unrelated and must not be touched. Everything lives in the `bd` schema, which is exposed to the Data API. Migration SQL lives in `supabase/migrations/`.
- Vercel: RenUSA team (`renusa`, team_Tc36Oh4fv0DbW6EpHfLWcGcA). No domain attached until Dave picks the subdomain.
- Style: light UI only. No em-dashes in any copy, commit messages, or drafts.
- Still open: Kate's and Ben's emails, subdomain name, Resend vs Gmail for alerts, the RenUSA contact CSV, the target-developer list, PJM Data Miner 2 key vs file download.

## TL;DR for the next thread

Dave wants a nationwide BD prospecting system for RenUSA, built to be turned on nationally but scoped for proof of concept to every state east of the Mississippi plus Louisiana, Arkansas and Texas. It watches three moments when RenUSA gets hired: (1) a developer enters an interconnection queue in a county with restrictive rules, (2) local opposition first organizes, (3) a project is denied, tabled or hit by a moratorium and needs a restart. It also watches people, because RenUSA's wins come from referrals and from known contacts moving to new developers. Build it as a web app on renusa.report (Next.js on Vercel, Supabase behind it) with Node cron jobs for bulk data collection and Claude scheduled tasks for enrichment, scoring and outreach drafting. No login for the proof of concept. First build step: schema, PJM queue ingestion, Sabin county risk overlay, scoring, and a Today view.

## Context the next Claude needs

- Dave D'Onofrio is SVP and East Team Head at RenUSA, a public affairs and community engagement firm for solar, wind, BESS and data center developers. He also runs The Casey Group.
- Users of this tool: Dave, Kate (RenUSA leadership; email not yet provided), Ben Kelahan (RenUSA co-founder, Dave's co-presenter on conference pitches), and RenUSA leadership generally. Four to six people.
- RenUSA already runs several Claude-built tools on the renusa.report domain: the Research Library at library.renusa.report (team login gate, rate limiting, Supabase) and client engagement dashboards such as longroad.renusa.report/yellowknight (Next.js on Vercel, Supabase project "longroad", ref ykxpfxxlgbdpdhhoikvn). This project follows the same pattern.
- Infrastructure decision from Dave: use the renusa GitHub org, the renusa Vercel team, and an existing Supabase project. (Resolved: see Confirmed facts above.)
- Dave receives Greenlight Weekly, a newsletter from Michael Grossman at Clean Up Marketing (michael@cleanupmarketing.com), every Wednesday. It lists permitting hearings and outcomes from the prior week for clean energy and data center projects with status tags (Approved, Active, Delayed, Denied, Restricted). Issue #25 (Sep 23, 2026) was the sample. Clean Up Marketing sells digital support campaigns to developers, so it is a partial competitor and its newsletter is a lead source, not a partner feed.
- Dave already runs a 3x weekly Leadership Brief as a Claude scheduled task. This system runs separately. The Brief is for reading; the Radar writes to a database.
- Dave's existing "Deep Dive Loop" analytical framework (current facts with [UNVERIFIED] flags, Decision Map, Whip Count, Opposition and Coalition, Timing and Leverage, Risks and Recommendation, self-critique) is the model for the enrichment a lead gets once it is Qualified.
- Dave dislikes generic "checking in" emails. Any outreach draft must give the recipient a real reason to reply and an easy out.
- There is an existing BD spreadsheet at RenUSA. This tool is for fresh leads only. A lead that reaches Conversation gets copied to the spreadsheet by hand. Do not integrate with the spreadsheet.
- Conflict checks against existing clients are done by humans. Do not build a conflict module.

## Decisions made

- Web app on renusa.report.
- No login for the proof of concept. Mitigation: unguessable subdomain or path, robots noindex, no sitemap. Add the Research Library style login gate before it goes beyond the four users.
- Build for nationwide from day one (state, ISO and territory fields everywhere, nothing hardcoded to a region) but only turn on feeds for the phase 1 footprint: every state east of the Mississippi River plus LA, AR, TX.
- MW floor is 50 MW for solar, wind and BESS. Data centers: any size.
- All three trigger points count (queue entry, opposition formation, post-denial), scored differently.
- No paid sources for now. Heatmap Pro is the one to revisit after 60 days if the Sabin county overlay is too coarse.
- Alerts: daily push of anything scoring 70 or above, Friday digest of everything new, dashboard as the system of record.
- Each lead has an owner.
- A dedicated Postgres schema named `bd` so prospecting data never mixes with other tables.
- Collection runs as Node cron jobs on Vercel (or Supabase edge functions), not inside Claude scheduled tasks, because the Claude cloud workspace has a restricted outbound network allowlist and cannot bulk-download from PJM, MISO, ERCOT or county sites. Claude scheduled tasks handle enrichment, scoring narrative, opposition sweeps via web search, and outreach drafts, reading and writing through the Supabase REST API.

## Technical state

- Stack: Next.js (App Router) on Vercel, Supabase Postgres with a `bd` schema, Vercel Cron for collection jobs (Node/TypeScript), Claude scheduled tasks for enrichment and drafting, Gmail connector for Greenlight ingestion, email delivery for alerts (Resend or the Gmail connector; Resend is simpler for cron-triggered sends).
- Env vars needed: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (server only), SUPABASE_ANON_KEY, CRON_SECRET, RESEND_API_KEY (if used), ALERT_RECIPIENTS (Dave, Kate, Ben). PJM Data Miner 2 API may require a free registered key [UNVERIFIED]; the PJM queue is also available as a downloadable file from the PJM planning pages.
- Known constraint: Claude cloud sessions cannot curl arbitrary sites; use WebFetch and WebSearch there, and do bulk pulls in Vercel cron.

## Architecture / approach

Two engines, one database.

Engine 1, Vercel Cron (Node): pulls structured feeds on a schedule, normalizes rows into `bd.signals` and upserts `bd.projects` and `bd.developers`. Deterministic, no LLM. Each feed is a module under `/lib/feeds/<feed>.ts` with `fetch()`, `parse()`, `normalize()` and a registry row in `bd.sources` with `last_run`, `last_status`, `row_count`.

Engine 2, Claude scheduled tasks: read new or changed records via Supabase REST, do the work that needs judgment: match a queue entry to a county and developer parent company, run the opposition sweep by web search, compute the narrative "why now" for a lead, draft outreach, and write results back. Each task is a standalone prompt because each firing starts a fresh session.

Scoring runs in Postgres (a function or a nightly job) from fields both engines populate, so the score is reproducible and the rubric lives in one place.

The web app is read-mostly with a few write actions: change stage, assign owner, add a note, mark a signal as noise, snooze.

### Data model (schema `bd`)

Column lists are the minimum; add timestamps and `created_by` everywhere.

- `developers`: id, name, parent_name, hq_state, website, technologies (array), known_to_renusa (bool), relationship_notes, linkedin_url.
- `projects`: id, name, developer_id, technology (solar | wind | bess | solar_bess | data_center | transmission | other), mw_ac, mw_storage, sq_ft, acres, state, county, fips, jurisdiction_name, iso, queue_id, queue_entered_at, stage, status_source, lat, lng, first_seen_at, last_signal_at, is_noise (bool).
- `signals`: id, project_id (nullable until matched), developer_id (nullable), source (enum: pjm_queue, miso_queue, nyiso_queue, isone_queue, ercot_gis, ercot_large_load, spp_queue, duke_queue, dominion_queue, southern_queue, tva_queue, sabin_restriction, sabin_contested, eia860m, greenlight, opposition_web, opposition_petition, people_move, developer_hiring, tdlr, usace, state_docket, county_agenda, news, manual), signal_type (queue_entry, queue_status_change, restriction_enacted, moratorium, opposition_group, petition, hearing_scheduled, denied, tabled, approved, withdrawn, job_change, hiring, permit_filed, docket_filed, news), headline, detail, url, observed_at, raw (jsonb), dedupe_key (unique). Also enriched_at (used by the enrichment task).
- `jurisdictions`: fips, state, county, name, has_restriction (bool), restriction_type, restriction_summary, restriction_effective, moratorium_until, contested_project_count, sabin_updated_at, risk_tier (1 to 5, derived).
- `people`: id, full_name, current_company, current_title, developer_id (nullable), linkedin_url, relationship_owner (Dave | Kate | Ben | other), relationship_strength (1 to 3), source (import | discovered), notes.
- `people_events`: id, person_id, event_type (title_change, company_change, new_hire_at_target), detail, url, observed_at.
- `leads`: id, project_id (nullable), developer_id, kind (project | developer | jurisdiction | person), score, score_breakdown (jsonb), stage (Signal | Qualified | Contacted | Conversation | Proposal | Won | Lost | Watch), owner, next_action, next_action_date, why_now (text, Claude-written), snoozed_until, closed_reason.
- `lead_notes`: id, lead_id, author, body, created_at.
- `outreach_drafts`: id, lead_id, recipient_person_id, channel (email | linkedin), subject, body, generated_at, approved (bool). Never auto-send.
- `alerts`: id, lead_id, kind (daily | weekly), sent_at, recipients.
- `sources`: key, label, cadence, last_run, last_status, last_error, row_count, enabled, footprint (array of states or 'all').

Stages for `projects.stage`: queue | state_prefiling | local_preapp | filed | contested | hearing | denied | tabled | approved | withdrawn | moratorium_blocked.

### Scoring rubric (0 to 100)

Five factors. Store the breakdown so the UI can show why.

- Fit (max 20): technology in scope (solar, wind, bess, data_center) 10; state in active footprint 5; size at or above floor 5 (data centers always get the 5).
- Stage (max 20): queue entry within 12 months 15; state pre-filing 20; local pre-app 20; filed with no hearing yet 15; contested 20; denied or tabled within 12 months 18; approved 5 (Watch bucket); withdrawn 0.
- Pain (max 25): county has a Sabin restriction 10; active moratorium 15; opposition group or petition found 15; prior denial in this county for same technology 5; cap at 25.
- Access (max 25): known person at developer with relationship_strength 3: 25; strength 2: 15; strength 1: 8; developer previously a RenUSA client or known_to_renusa: 10; recent people_event linking a known person to this developer: +10; cap at 25.
- Competition (subtract up to 10): evidence another engagement or digital firm is already on the project (campaign microsite, named PR contact in coverage, Clean Up Marketing case study) minus 10; unknown 0.

Thresholds: 70 and above triggers the daily alert and auto-moves to Qualified for review; 50 to 69 sits in Signal; under 50 is visible but filtered out by default. Dave, Kate and Ben should be able to edit weights from a settings table without a deploy.

### Feeds

Phase 1 (build first, in this order):

1. PJM interconnection queue. Source: pjm.com planning pages, downloadable queue file, or Data Miner 2 API [free key, UNVERIFIED]. Weekly. Fields: queue number, project name, developer (often an LLC; capture as-is and let Claude resolve parent), fuel, MW, state, county, status, dates. Filter: 50 MW and up, states in footprint. Diff against last run: new entries and status changes become signals.
2. Sabin Center Opposition Report data. Source: oppositionreport.org/reports/current, downloadable Restriction and Contested Project files. Updated monthly (last update Sep 8, 2026). Populate `jurisdictions` and create `sabin_restriction` and `sabin_contested` signals on change. Sabin restriction data covers wind, solar, storage and transmission; it does not cover data center ordinances.
3. Greenlight Weekly ingestion. Gmail search for sender michael@cleanupmarketing.com, subject "Greenlight Weekly", weekly on Wednesday. Parse each entry: project, applicant, location, date, status tag, technology tag, one-line outcome. Write as `greenlight` signals with signal_type mapped from the status tag. Match to existing projects by name plus county; create new ones otherwise. Claude task is faster to ship.
4. MISO, NYISO, ISO-NE, ERCOT GIS, SPP queues, same module pattern. ERCOT large-load list as `ercot_large_load`.
5. Southeast non-ISO utilities: Duke, Dominion, Southern Company and TVA via OASIS. Build what is public, log the rest as gaps in `sources`.
6. Opposition sweep (Claude task, weekly). For every project in stage queue, state_prefiling, local_preapp or filed with score 40 or above, web-search "<county> <technology> opposition", "stop <project name>", "no <technology> <county>", change.org "<county> <technology>". Write `opposition_web` or `opposition_petition` signals with URLs.
7. People feed. CSV import of RenUSA's contact list into `people`, then a weekly Claude task checking strength 2 or 3 people for job changes and a target-developer list for engagement/permitting/public affairs hiring. Write `people_move` and `developer_hiring` signals.
8. EIA-860M monthly planned generator additions as a cross-check.

Phase 2 and 3 (later): TDLR, USACE district notices, state dockets, county agenda scraping (Legistar, CivicPlus, Granicus), economic development announcements, SoS LLC formations, utility IRPs, regional news, Data Center Watch; then CAISO/West and territory routing.

### Web app

Follow the RenUSA Dashboard Template: Bebas Neue headers, Source Sans 3 body; navy #0A2240 dominant, cream #F5F3EE surfaces, red #B03030 for the top stripe only, gold #C8963C only for thin rules and the active nav tab. Header: red top stripe, navy background, thin gold bar. Reference file: pleasant_valley_dashboard_v2.html (in the renusa repos; ask Dave if you can't find it). Gold sparingly. Page bodies stay light.

Routes:
- `/` Today: new leads scoring 70 and above since yesterday, then everything new this week, each card with score, breakdown, why_now, owner, next action. One-click stage change and owner assignment.
- `/pipeline`: table with stage, owner, technology, state filters and score sort.
- `/projects/[id]`: project record, signal timeline, county risk panel, developer panel, known people, outreach drafts, notes.
- `/developers/[id]`, `/people`, `/map` (can wait), `/sources` (feed health), `/settings` (score weights, alert recipients, footprint toggle per state).

Add `<meta name="robots" content="noindex, nofollow">`, no sitemap, and optionally a middleware check for a long random path prefix or shared header token.

### Alerts

- Daily 7:00 AM Eastern: email to Dave, Kate, Ben listing leads that crossed 70 in the last 24 hours. Skip if nothing crossed.
- Friday 4:00 PM Eastern: digest of every new signal and lead this week, grouped by technology and state, plus people_events and feed health.

### Claude task prompts (drafts)

Enrichment (daily): fetch `bd.signals` where `enriched_at` is null, up to 50; resolve developer LLC to parent; confirm county/state; note current news; create a lead if none; write `why_now` in two or three plain sentences, direct consulting voice, no em-dashes; set `enriched_at`; mark obvious noise (repowering, sub-50 MW renewables, transmission-only) `is_noise`.

Outreach draft: first-contact email from Dave, lead with one specific verifiable fact about their situation in the county, offer one concrete thing, give an easy out, under 150 words, no em-dashes, no "checking in"/"hope this finds you well"/"I wanted to reach out". Save to `outreach_drafts`, approved false.

### Seed leads from Greenlight Issue #25 (load as manual signals on day one)

- Crossroads Technology Campus, RCK Digital Crossroads LLC / Amazon Web Services, Spotsylvania County VA, ~555 acres, PC recommended approval 4-2 Sep 16, Board vote pending. Stage: filed.
- Dulles Technology Park, B.F. Saul Company, Loudoun County VA, ~37-acre rezoning, PC recommended denial 5-4 Sep 17; Loudoun Board approved a 12-month pause on final votes for qualifying data center and substation applications Sep 15. Stage: contested.
- NextEra Energy Transmission Virginia facilities, Frederick County VA, SCC public witness hearing Sep 16. Stage: state_prefiling.
- MNZ07 Wellington campus, Microsoft, Prince William County VA, two buildings on ~123 acres, USACE wetlands permit under review Sep 16. Stage: filed.
- 900 Conshohocken Road data center, MLP Ventures, Plymouth Township PA, zoning hearing canceled Sep 17 on a Sunshine Act posting defect. Stage: tabled.
- IM Pittsburgh generator variances, IM Pittsburgh LLC, Wilkinsburg PA, hearing continued Sep 17. Stage: tabled.
- Scott County VA data center zoning ordinance, PC tabled Sep 14. Jurisdiction lead.
- Statesville NC 180-day data center moratorium and Vance County NC 60-day moratorium (both Sep 14). Jurisdiction leads.
- Project Delta, Engineered Land Solutions / DFC Stokes LLC, Stokes County NC, ~1,849 acres, conditional rezoning approved Sep 14. Stage: approved (Watch).
- Islip NY large-scale BESS prohibition affecting Key Capture Energy's 79 MW Rabro Drive project; Dunkirk NY BESS moratorium extension. Both Sep 15. Stage: moratorium_blocked. RenUSA's Marathon Power BESS work in Huntington NY is the credential.
- Huron County MI solar and BESS ordinance deliberations, Sep 16. Jurisdiction lead.
- Gallatin TN data center moratorium advanced on first reading Sep 15. Jurisdiction lead.
- Outside East footprint, flag for other team heads: Project Bluestem (Cloverleaf Infrastructure, Tonganoxie KS, ~1.2 GW), Monolith / Crusoe Hallam NE (~35 MW SUP recommended), Clackamas County OR moratorium hearing.

### Sources consulted

- Sabin Center Opposition Report: https://oppositionreport.org/reports/current/
- Columbia Climate Law Blog, 6th edition: https://blogs.law.columbia.edu/climatechange/2026/09/03/widespread-local-opposition-often-driven-by-misinformation-continues-to-hamper-renewable-energy-development/
- Data Center Watch via Bloomberg: https://www.bloomberg.com/news/articles/2026-09-21/new-data-centers-worth-68-billion-disrupted-in-us-data-show
- NBC News on Data Center Watch Q1 2026: https://www.nbcnews.com/tech/tech-news/data-center-opposition-sharply-rising-2026-study-finds-rcna349728
- Heatmap Pro: https://heatmap.news/pro

Not verified: PJM Data Miner 2 API access terms, exact download URLs and formats for each ISO and utility queue, Santee Cooper and FPL queue availability, Heatmap Pro pricing.

### Open questions and next steps

1. (Resolved) Supabase ref confirmed: csxvtewzlhigrzvpxtvf, `bd` schema.
2. Confirm subdomain name and whether a light barrier is wanted.
3. Get Kate's email; confirm Ben's.
4. Get the RenUSA contact list export for `people`.
5. Get a target-developer list (10 to 30 names).
6. Build order: schema and migrations; PJM feed; Sabin overlay; scoring function; Today and Pipeline pages; Greenlight parser; daily alert. Then other ISOs; opposition sweep; people watch; Friday digest. Then phase 2.
7. Register PJM Data Miner 2 key if needed, or confirm the file download route.
8. Resend vs Gmail for alerts.
9. Dave offered a manual first sweep (PJM queue, 50 MW and up, last six months, Sabin overlay, top 25 scored) to validate the rubric. Do it early.
