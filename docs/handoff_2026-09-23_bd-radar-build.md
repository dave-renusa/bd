# Handoff: RenUSA BD Radar, build and first iteration

**Date:** 2026-09-23
**Original thread purpose:** Build the RenUSA BD Radar from `docs/handoff_2026-09-23_bd-radar.md` (schema, PJM feed, Sabin overlay, scoring, Today page), then iterate on it with Dave.
**Status:** Live and in use. Paused at a clean point; next phase is national expansion (see `docs/expansion-playbook.md`).

**Sensitivity note:** No personnel or legal material. The site is behind an access link (key in Dave's bookmark, not in this file). Env var names appear below; no secret values do.

## TL;DR for the next thread

The BD Radar is live at bd.renusa.report (Next.js on Vercel, Supabase `bd` schema). It ingests PJM's interconnection queue, the Sabin Center Opposition Report and Greenlight Weekly (via a weekly Claude routine reading Gmail), scores every lead 0 to 100, and shows them on Home, Pipeline (list, map, search) and Sources. 15 PRs are merged; the database holds 1,044 leads (151 at 50+), 966 projects, 1,961 signals and 331 developers. No lead reaches 70 yet because Access points need RenUSA's contact list and target-developer list, which have not been loaded. First actions for the next thread: confirm Dave added the Gmail and Supabase connectors to the Greenlight routine (it fires Wed Sep 30, 15:00 UTC), then start the national expansion with MISO and SPP.

## Context the next Claude needs

- **People:** Dave D'Onofrio (dave@renusa.org; Gmail and Claude account ddonofrio@thecaseygroup.us). Kate and Ben are future owners and alert recipients. Owners list setting: Dave, Kate, Ben.
- **Style rules:** light UI only; no em-dashes anywhere (copy, commits, drafts, docs); RenUSA template: Bebas Neue headings, Source Sans 3 body, navy #0A2240 dominant, cream #F5F3EE surfaces, red #B03030 top stripe only, gold #C8963C for thin rules and the active tab only. Dave asked for Apple-style polish within that brand (applied).
- **Repo:** `dave-renusa/bd`, default branch `main`. Claude merges its own PRs (Dave authorized "merge it yourself and make live"). Commits end with the Claude co-author and session trailers.
- **Supabase:** project `csxvtewzlhigrzvpxtvf` ("BD Database"). Everything lives in schema `bd`; `bd` is exposed to PostgREST; RLS on with no policies (service_role only). Never touch `public` (it has an unrelated `public.support_messages`). Dave approved Claude making SQL changes; `.claude/settings.json` allows `mcp__Supabase__execute_sql` and `apply_migration` without prompts.
- **Vercel:** team RenUSA `team_Tc36Oh4fv0DbW6EpHfLWcGcA`, project `bd`. Production deploys on push to `main`. Domain bd.renusa.report (GoDaddy CNAME). Env vars: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, `CRON_SECRET`, `SITE_KEY`, optional `PJM_QUEUE_FILE_URL`, `PJM_QUEUE_SUBSCRIPTION_KEY`, `PJM_API_KEY` (reserved), `SABIN_RESTRICTIONS_URL`, `SABIN_CONTESTED_URL`, `ALERT_RECIPIENTS`, `RESEND_API_KEY` (not set yet).
- **Access:** `proxy.ts` gates every page with a `SITE_KEY` cookie set by visiting `/?key=...`. Cron routes are excluded and use `CRON_SECRET`. Claude's tools cannot open the site (Vercel SSO redirect for previews, key gate for production), so Dave clicks Run now on /sources when a feed needs a manual run.
- **Dave's network:** his home wifi DNS returned NXDOMAIN for the new subdomain; fixed by setting the Mac to Google DNS (8.8.8.8).
- **Greenlight routine:** trigger `trig_01WLcoz2Kcf7wwhxfR2n8oxg`, "BD Radar: Greenlight Weekly ingest", cron `0 15 * * 3` (Wednesdays 15:00 UTC), fresh session each run. Prompt source of truth: `docs/greenlight-routine.md`. It has NO connectors attached (the connectors parameter was unavailable to Claude); Dave must add Gmail and Supabase in claude.ai Routines. Greenlight sender: michael@cleanupmarketing.com (Clean Up Marketing, a partial competitor; the newsletter is a lead source, not a partner).
- **Local test DB:** Postgres 16 at `/var/tmp/pgbd`, port 54329 (start: `su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /var/tmp/pgbd/data -l /var/tmp/pgbd/log -o '-p 54329 -k /var/tmp/pgbd' -w start"`); `/var/tmp/resetdb.sh` rebuilds database `bdtest` from all migrations. These live in the ephemeral container and will not survive a new session; recreate if needed.
- **Verification habit:** after changing a function live, compare `md5(pg_get_functiondef(...))` against the local copy.

## What we did

1. **Foundation (PR #1):** schema (enums, tables, touch triggers, RLS, grants), config seed (footprint, score weights, settings, sources), functions (county matching, developer upsert, queue and Sabin ingest, scoring, lead view), 3,194 county and state jurisdictions with FIPS, 18 seed leads from Greenlight Issue #25, people import path (CSV), Today, Pipeline and Sources pages, cron routes, alert email code (Resend, not yet keyed).
2. **Deploy fixes:** Vercel framework preset, CRON_SECRET re-added, subdomain attached, DNS walkthrough.
3. **Run now buttons and Greenlight ingestion (PR #2):** `bd.ingest_greenlight`, the weekly routine.
4. **Sabin discovery and county matching (PR #3):** WordPress export links, looser county matching ("King and Queen", "DeWitt", "City of X"), PJM queue-note stripping, Greenlight backfill guard.
5. **Greenlight backfill (PR #4):** Issues #21 to #25 loaded (142 signals); fallback matcher limited to hand-entered items after it merged unrelated items; routine prompt handles both newsletter layouts and WITHDRAWN.
6. **Sabin live columns (PR #5):** Title, Type, Content, Post iD; restriction types from rule labels; expired rules skipped; lifted moratoria no longer flag tier 5; Sabin rebuilt (821 restrictions, 568 contested).
7. **Search and stage guide (PR #6):** `bd.search_leads` (keywords over names, places and all signal text), header search, state dropdown, plain-English permitting labels.
8. **Four stages (PR #7):** New, Working, Closed (won, lost, dead), Watch. Rescore no longer auto-moves stages.
9. **Home and design refresh (PR #8):** "Today" renamed "Home" at Dave's choice; Apple-style polish within the brand.
10. **Sabin link fix (PR #9):** first URL from citations; only real web addresses are linked.
11. **Stale leads (PR #10):** cap at 30 after `stale_months` with no activity; Closed: dead project; Pipeline hides Closed by default.
12. **Map and location line (PR #11):** Leaflet map on Pipeline, county centroids file, location under lead names.
13. **Duplicate merge (PR #12):** same name, state and county merge; 88 duplicates folded into 73.
14. **Developer line and compact Pipeline rows (PR #13).**
15. **Honest dates (PR #14):** year-only dates show as the year; queue projects labeled "In queue since"; stale window 18 months.
16. **Developer enrichment (PR #15):** 566 Sabin descriptions read by Claude; 377 developers loaded; weekly routine step 5 keeps it current.

## Decisions made

- Everything in schema `bd`, migrations in `supabase/migrations/`, because the handoff required it and it keeps `public` untouched.
- PJM via the public queue export with a `PJM_API_KEY` hook, because Dave's Data Miner signup threw server errors.
- Greenlight via a Claude routine reading Gmail directly, because Dave did not want to forward emails.
- Alerts to dave@renusa.org only, via Resend from Vercel cron, because it is the simplest cron-triggered sender. Kate and Ben later.
- "Home" not "Today", because Dave chose it over the recommendation.
- Four sales stages (New, Working, Closed with won/lost/dead reason, Watch), because Dave chose "Merge to 4".
- Crossing 70 stamps `qualified_at` only and does not change our stage, because stage is a human decision.
- Stale cap: 18 months, cap 30, because Dave found 2025 and older "hard to think these are active".
- Old PJM queue requests stay in view (no stale cap for stage `queue`), because Dave chose to keep them: long-queued projects may be nearing local permitting.
- Duplicates merge only within the same county, because the same name in another county may be a different site.
- Representative record order: Greenlight or manual, then Sabin, then queue, because richer and newer records should drive stage and score.
- Map points at county centroids from a static JSON file, because no source gives site coordinates and the database load was too large for the SQL tool.
- Developer enrichment only fills blanks and never overwrites, because feed or human data should win over text extraction.

## Artifacts and outputs

- **Live site:** https://bd.renusa.report (Home, /pipeline with List and Map, /sources).
- **Repo:** https://github.com/dave-renusa/bd (PRs #1 to #15 merged; this handoff and the playbook are in the PR after #15).
- **Docs:** `docs/handoff_2026-09-23_bd-radar.md` (original design handoff), `docs/greenlight-routine.md` (routine prompt), `docs/expansion-playbook.md` (national expansion seeds), this file.
- **Migrations:** `supabase/migrations/20260923000001` to `...000018` (schema through developer enrichment).
- **Feeds:** `lib/feeds/pjm.ts`, `lib/feeds/sabin.ts`, `lib/feeds/run.ts`; cron routes `app/api/cron/{pjm,sabin,score,daily-alert}`; manual runs `app/api/run/[job]`.
- **Data file:** `lib/county-centroids.json` (3,287 county and state centers, from us-atlas via d3-geo).
- **Scripts:** `scripts/import-people.ts` (contact CSV), `scripts/import-sabin.ts` (manual Sabin load).
- **Tests:** `tests/feeds.test.ts` (10 passing).

## Open questions and next steps

1. **Before Wed Sep 30:** Dave adds Gmail and Supabase connectors to the routine in claude.ai Routines. Without them the run fails.
2. **Resend setup:** signup, verify a sending domain (renusa.org or a subdomain), set `RESEND_API_KEY` in Vercel. Walk Dave through it when he is ready.
3. **Contact CSV and target-developer list:** the biggest scoring gap. Access points (up to 25) come only from `bd.people` and `bd.developers.known_to_renusa`. Nothing can reach 70 without them (max without Access is 65 today).
4. **Developer name variants:** NextEra appears as "NextEra", "NextEra Energy", "NextEra Energy Resources" (similar for Invenergy LLC, Savion Energy, Iberdrola). Normalize to one developer with parent before Access scoring by developer.
5. **National expansion:** follow `docs/expansion-playbook.md`. Recommended order: MISO, SPP, EIA-860M, NYISO, ISO-NE, ERCOT GIS, CAISO, then non-RTO utilities.
6. **PJM new-cycle gap [UNVERIFIED]:** the PJM export has no queue entries from the last 12 months. IDs show "moved to TC2", so new Cycle 1 requests are likely published elsewhere. Confirm and add.
7. **Sabin ban vs moratorium:** Sabin's "Ban / Moratorium" rule label lumps both; 316 counties sit at risk tier 5. Splitting needs parsing rule text; unclear if feasible.
8. **Open enrichment tasks from the design handoff:** why-now text (cards show "awaiting enrichment"), opposition web sweep, people and hiring watch, Friday digest.

## Things tried that didn't work

- **Census gazetteer download for centroids:** blocked by the sandbox network policy; used the us-atlas npm package instead.
- **Loading centroids into the database via the SQL tool:** about 80 KB of SQL was too heavy; shipped as a static JSON file instead and reverted the two empty columns.
- **Subagents writing to the database:** auto mode blocked some writes as shared-resource modifications. Keep subagents read-only and run writes from the main session.
- **Map tiles and external feeds from this sandbox:** OpenStreetMap, MISO, SPP, NYISO, ISO-NE, CAISO, EIA and ERCOT all time out here. Vercel can reach PJM and Sabin, so test new feeds with Run now on /sources.
- **Greenlight same-county-same-date fallback matching:** merged unrelated items (Coachella into Palm Springs, AB 2383 into AB 2469). Now limited to `manual:` items.
- **Sabin column guesses:** the first aliases missed Title, Type and Content; always inspect `raw` after a first run.
- **`apply_migration` with a placeholder body:** once recorded a migration name with `select 1`; always send the real SQL.
- **A single query that runs `bd.run_scoring()` and reads results:** reads see the pre-run snapshot. Verify in a second query.

## How to resume

Paste this file into a new Claude Code session on `dave-renusa/bd` and say: "Read docs/handoff_2026-09-23_bd-radar-build.md and docs/expansion-playbook.md. Check that the Greenlight routine has its connectors and that the Sep 30 run succeeded (bd.source_runs), then build the MISO queue feed per the playbook."

## Technical state

- **Stack:** Next.js 16 App Router (`proxy.ts` replaces middleware; server actions), TypeScript, exceljs and papaparse for sheets, Leaflet 1.9 for the map, Vitest. Supabase Postgres 17 with plpgsql functions. Vercel Cron. Claude routine for Greenlight and developer enrichment.
- **Repo layout:** `app/` (pages, cron and run routes, `lead-card.tsx`, `lead-controls.tsx`, `stage-guide.tsx`, `pipeline/lead-map.tsx`), `lib/` (db client, feeds, sheets helpers, states, stages, leads queries, alerts), `supabase/migrations/`, `scripts/`, `tests/`, `docs/`.
- **Schedules (UTC):** PJM Mon 10:00, Sabin Tue 10:00, rescore daily 10:30, daily alert 11:00, Greenlight routine Wed 15:00.
- **Settings (bd.settings):** mw_floor 50, qualify_threshold 70, signal_threshold 50, stale_months 18, stale_cap 30, owners, alert_recipients.
- **Footprint enabled:** AL, AR, CT, DC, DE, FL, GA, IL, IN, KY, LA, MA, MD, ME, MI, MS, NC, NH, NJ, NY, OH, PA, RI, SC, TN, TX, VA, VT, WI, WV. Off: all western and plains states plus MN. Queue feeds skip rows outside the enabled footprint.
- **Known quirks:**
  - Sabin dates are year-only, stored as Jan 1.
  - Sabin and queue signals carry the download date, so `score_lead` ignores them for staleness (a hardcoded source list; extend it for new queue sources).
  - Leads with no county (statewide, federal) do not appear on the map.
  - Three defunct counties lack centroids.
  - `bd.search_leads` caps at 500 rows (UI) or 1,000.

## Architecture / approach

- **Pipeline of data:** feeds normalize rows in TypeScript (`lib/feeds/*.ts`), then call one plpgsql ingest function per source (`bd.ingest_queue`, `bd.ingest_sabin`, `bd.ingest_greenlight`), which upserts `bd.projects`, writes deduplicated `bd.signals`, and ends with `bd.run_scoring()`.
- **Scoring:** `bd.run_scoring()` runs `refresh_jurisdiction_risk`, `merge_duplicate_projects`, `ensure_project_leads` and `rescore_leads`. `bd.score_lead` computes Fit 20, Timing 20, Pain 25, Access 25 and Competition minus 10 from `bd.score_weights`, then applies the stale cap. The breakdown JSON holds reasons, `last_activity` and `stale`.
- **Read path:** the site reads `bd.lead_view` (lead plus project, county risk, developer and latest signal) and `bd.search_leads` for Pipeline.
- **Idempotence:** every ingest is safe to re-run (dedupe keys, upserts, merge re-run on every scoring pass).
- **Human state:** our stage, owner, snooze and notes are never overwritten by feeds. A worked lead survives merges.
