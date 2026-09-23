# BD Radar expansion playbook: other grid operators and national sources

Seeds for taking the BD Radar from PJM plus the East to every US grid operator and national source. Use it with `docs/handoff_2026-09-23_bd-radar-build.md`.

**Verification status:** none of the URLs below could be tested from the build sandbox. Its network policy blocked every one of them, including PJM, which works fine from Vercel. Every URL, file layout and column name here is a starting point marked [UNVERIFIED] until a first run from Vercel (Run now on /sources) confirms it. Most queue URLs are the ones the open-source `gridstatus` Python library uses (github.com/gridstatus/gridstatus, BSD-3). Its code is the best reference for each operator's current endpoint and column names.

## 1. Going national: switches to flip first

1. **Footprint:** queue feeds skip states that are off in `bd.footprint`. Today MN and all western and plains states are off. To go national:
   ```sql
   update bd.footprint set enabled = true where not enabled;  -- or a named list of states
   ```
   Fit scoring gives 5 points for an enabled state, so leads in newly enabled states score correctly with no other change.
2. **Sabin and Greenlight are already national.** Their leads in currently disabled states exist but lose the 5 footprint points. Enabling states lifts them on the next rescore.
3. **Scale checks before adding ISOs:**
   - MISO, SPP, ERCOT and CAISO each have thousands of active requests. Keep the 400-row chunking in `runPjm` and the 300-second `maxDuration`.
   - `bd.rescore_leads` skips unchanged leads, so the nightly run stays fast.
   - `bd.search_leads` caps at 500 rows in the UI, so users should filter by state once the lead count grows.
4. **MW floor:** `mw_floor` is 50. Western and plains solar and wind projects are larger, so 50 is still a reasonable floor. Storage-only requests are often 20 to 100 MW, so check the effect before raising it.

## 2. Recipe: adding one queue feed

Every ISO queue follows the PJM pattern. Checklist:

1. **Normalizer:** `lib/feeds/<iso>.ts`, modeled on `lib/feeds/pjm.ts`. Export `fetch<Iso>Queue()`, `parse<Iso>Queue()` (use `readSheet` or `readCsv` from `lib/sheets.ts`) and `normalize<Iso>(rows, { mwFloor, footprint })`, returning `QueueRow[]`:
   `queue_id, name, developer, technology, mw_ac, mw_storage, state, county, status, is_withdrawn, is_built, entered_at, url, raw`.
   - Use `columnPicker` with alias lists. Operators rename columns.
   - Map fuel to technology like `pjmTechnology`. Hybrids (solar plus storage) map to `solar_bess`.
   - Normalize state with `toStateCode`.
   - Keep the county as printed. `bd.match_county` handles "X County", parishes and independent cities, and splits on `; , & /`.
   - Put withdrawn and in-service detection in `is_withdrawn` and `is_built`. The database never creates a new project from those rows but updates tracked ones.
2. **Runner:** `run<Iso>()` in `lib/feeds/run.ts`, a copy of `runPjm` that passes `p_source` (enum) and `p_iso` (text such as `'MISO'`) to `rpc('ingest_queue', ...)`. The unique key is `(iso, queue_id)`.
3. **Routes:**
   - Cron: `app/api/cron/<iso>/route.ts`, a copy of `app/api/cron/pjm/route.ts`.
   - Schedule: add it to `vercel.json`. Stagger schedules; each ISO updates at most weekly.
   - Manual run: add the job to `app/api/run/[job]/route.ts` and the `RUNNABLE` map in `app/sources/page.tsx`.
4. **Enum:** `bd.signal_source` already has `miso_queue, nyiso_queue, isone_queue, ercot_gis, ercot_large_load, spp_queue, duke_queue, dominion_queue, southern_queue, tva_queue, eia860m`. Add any missing value in a migration, for example `alter type bd.signal_source add value 'caiso_queue';`. Western utilities need values too.
5. **Staleness list:** `bd.score_lead` ignores download-dated sources when computing last activity. Add the new source to its `s.source not in (...)` list in the same migration, or it will make every queue lead look freshly active.
6. **Sources row:** `update bd.sources set enabled = true, notes = '...' where key = '<key>';`, or insert a new row for a new key.
7. **Test:** add a fixture test to `tests/feeds.test.ts` built from the real header row, captured from the first successful run's `raw` column.
8. **First run:** Dave clicks Run now on /sources. Then check `bd.source_runs.detail` for `file_rows`, `in_scope` and the matched counts. Inspect a few `raw` rows and fix aliases before trusting it.
9. **Duplicates:** nothing to do. `bd.merge_duplicate_projects` folds same-name, same-county projects across ISOs, Sabin and Greenlight on the next scoring run.

## 3. Grid operator seeds

Order is by value to RenUSA's footprint and ease.

### MISO (Midwest and Louisiana, Arkansas, Mississippi, east Texas) [UNVERIFIED]
- **Endpoint:** JSON API `https://www.misoenergy.org/api/giqueue/getprojects` (used by gridstatus). Public queue page: misoenergy.org, "Generator Interconnection Queue".
- **Likely fields:** `projectNumber` (queue ID), `county`, `state`, `fuelType`, `summerNetMW`, `winterNetMW`, `applicationStatus` (Active, Withdrawn, Done), `queueDate`, `inService`, `poiName`, `transmissionOwner`, `studyCycle`, `studyPhase`. No developer column.
- **Notes:** a JSON feed needs a `readJson` path instead of `readSheet`. MISO's DPP cycles make queue dates cluster; `studyPhase` could feed the Timing score later.
- **Value:** high. It covers IL, IN, MI, WI, MN, IA, MO, AR, LA, MS and east TX, many of them already in footprint.

### SPP (plains: KS, OK, NE, the Dakotas, parts of TX, NM, MO, AR, LA) [UNVERIFIED]
- **Endpoint:** CSV `https://opsportal.spp.org/Studies/GenerateActiveCSV` (used by gridstatus). The first line is a title row, so the header is on line 2; `readSheet` with header hints handles this.
- **Likely fields:** `Generation Interconnection Number`, `County`, `State`, `Fuel Type`, `Capacity`, `Status`, `Request Received`, `Proposed Completion Date`, `TO at POI`.
- **Value:** high for wind and solar volume.

### NYISO (New York) [UNVERIFIED]
- **Endpoint:** Excel `https://www.nyiso.com/documents/20142/1407078/NYISO-Interconnection-Queue.xlsx` (used by gridstatus; the path has changed before). The workbook has several sheets: active queue, cluster projects, in service, withdrawn.
- **Likely fields:** `Queue Pos.`, `Developer/Interconnection Customer` (a developer column), `Project Name`, `County`, `State`, `Type/ Fuel`, `SP (MW)`, `WP (MW)`, `Date of IR`, `Proposed COD`, `S` (status code).
- **Notes:** read every sheet and tag withdrawn and in service from the sheet name. NY ORES (below) is the matching state siting source.
- **Value:** high. NY is in footprint and the file names developers, which directly helps Access scoring.

### ISO-NE (New England) [UNVERIFIED]
- **Endpoint:** Excel export `https://irtt.iso-ne.com/reports/exportpublicqueue` (used by gridstatus). Interactive page: irtt.iso-ne.com/reports/external.
- **Likely fields:** `Position`, `Alternative Name`, `Fuel Type`, `County`, `ST`, `Net MW`, `Summer MW`, `Requested`, `Status`, `W/D Date`, `Op Date`, `Unit`.
- **Value:** medium. There are many small projects under the MW floor.

### ERCOT GIS report (Texas) [UNVERIFIED]
- **Source:** the monthly "GIS Report" workbook on ERCOT's MIS, report type 15933 in gridstatus ("GIS Report"). The ERCOT public API (apiexplorer.ercot.com) needs a free registered subscription key, so set an `ERCOT_API_KEY` env var like the PJM hook.
- **Layout:** multi-tab Excel with a "Project Details - Large Gen" tab that has a header block of about 30 rows (gridstatus skips them). Likely fields: `INR` (queue ID), `Project Name`, `Interconnecting Entity` (developer), `County`, `Fuel`, `Technology`, `Capacity (MW)`, `Projected COD`, `GIM Study Phase`, and milestone dates such as `Screening Study Started` and `FIS Approved`.
- **Notes:** ERCOT is Texas-only, so state is always TX. The milestone dates are real activity dates and can feed staleness properly, unlike download dates.
- **Value:** high (TX is in footprint), and the file names developers.

### ERCOT large-load interconnection status (data centers) [UNVERIFIED]
- **Source:** ERCOT posts a periodic large-load interconnection status report (loads of 75 MW and up) under Grid Info or Resource Adequacy. The exact URL and cadence are unverified. Recent reports are aggregated by status and zone rather than by project, so they may only support a jurisdiction-level signal.
- **Signal source:** `ercot_large_load` already exists. Greenlight's "ERCOT Batch Zero" items show the topic is live.

### CAISO (California) [UNVERIFIED]
- **Endpoint:** Excel `https://www.caiso.com/documents/publicqueuereport.xlsx` (older path `http://www.caiso.com/PublishedDocuments/PublicQueueReport.xlsx` returned 403 from the sandbox, so it probably moved). Sheets: "Grid GenerationQueue", "Completed", "Withdrawn".
- **Likely fields:** `Project Name`, `Queue Position`, `Interconnection Request Receive Date`, `Application Status`, `Type-1`, `Fuel-1`, `MW-1` (several fuel and MW pairs), `County`, `State`, `Utility`.
- **Needs:** a new enum value `caiso_queue`, and CA enabled in footprint.
- **Value:** medium for RenUSA (CA is off today), high if the business goes national.

### PJM new cycle (gap in the current feed) [UNVERIFIED]
- **The gap:** the current export has no entries from the last 12 months and many IDs read "moved to TC2", so post-transition Cycle 1 requests likely live elsewhere.
- **Where to look:** PJM's "Queue Scope" pages, the Cycle 1 application list, or Data Miner 2 with `PJM_API_KEY` once Dave's signup works.
- **First step:** open the PJM interconnection queues page and list which exports exist now.

### Non-RTO utilities (Southeast and West) [UNVERIFIED]
- **Where the data is:** these publish generator interconnection queues on their OASIS sites (many on OATI, oasis.oati.com, some needing free registration) or on their own interconnection pages, as Excel or PDF. Treat each as its own small feed or a monthly Claude task. Formats vary and change.
- **Southeast (signal sources exist):**
  - Duke Energy (Carolinas, Progress, Florida): `duke_queue`.
  - Southern Company (Georgia Power, Alabama Power, Mississippi Power): `southern_queue`.
  - TVA: `tva_queue`.
  - Also: Santee Cooper, Dominion Energy South Carolina, FPL, and Entergy (Entergy is in MISO, so it is covered there).
- **Dominion Virginia is inside PJM,** so `dominion_queue` is redundant unless it is repurposed for Dominion's large-load (data center) filings.
- **West (new enum values needed):**
  - PacifiCorp, NV Energy, APS, SRP, TEP, Xcel (PSCo), Idaho Power, Portland General, Puget Sound Energy, BPA, El Paso Electric, PNM.
- **Approach:** the `southeast_utilities` source row notes say "log public vs gap per utility". Start with a one-time Claude research pass recording, per utility, the queue URL, format and whether it names county and developer. Then build file feeds only for the clean ones.

## 4. National non-queue sources

### EIA-860M (monthly, every planned US generator) [UNVERIFIED]
- **Where:** https://www.eia.gov/electricity/data/eia860m/ publishes a monthly Excel workbook with "Operating", "Planned", "Retired" and "Canceled or Postponed" sheets. There are about two header rows above the column names.
- **Why it matters:** it has latitude and longitude, operator (developer) names, planned operation month and year, and a status code: (P) planned, not under construction; (L) regulatory approvals pending; (T) approvals received, not under construction; (U) under construction, 50 percent or less; (V) under construction, more than 50 percent; (TS) construction complete, not operating; (OT) other.
- **How to load:** status maps to stage (P to queue or state_prefiling; L to filed; T to approved; U and V to approved and Watch).
- **Payoff:** it gives real developer names nationwide, fills the Access gap, and allows true map pins instead of county centers.
- **Signal source:** `eia860m` already exists.

### LBNL "Queued Up" (annual, every US queue in one file) [UNVERIFIED]
- **Where:** Lawrence Berkeley National Lab publishes a cleaned, national interconnection queue dataset each year at https://emp.lbl.gov/queues, with state, county, fuel, MW, queue date, status and ISO or utility.
- **Use:** a one-time national backfill and a cross-check for the per-ISO feeds, especially the non-RTO utilities. It lags about a year, so it is not a live feed.

### US Wind Turbine Database and US Large-Scale Solar Photovoltaic Database [UNVERIFIED]
- **What:** USGS and LBNL datasets of built projects with coordinates (eerscmap.usgs.gov/uswtdb; USPVDB via the same USGS portal).
- **Use:** context layers for the map and "prior projects in this county". Not leads.

### State siting and docket sources (Claude tasks, not files)
State boards are where projects become contested, which is RenUSA's moment. Seed list [UNVERIFIED portals]:
- **New York ORES** (Office of Renewable Energy Siting): permit applications and hearing notices.
- **Ohio Power Siting Board:** case dockets for wind and solar of 50 MW and up.
- **Michigan PSC:** PA 233 siting cases (state preemption since late 2024), which appear often in Greenlight.
- **Virginia SCC:** CPCN and data center load cases; **Virginia DEQ:** Permit by Rule notices for solar.
- **Illinois:** county-level siting under the 2023 state siting standards law; county board agendas.
- **Indiana IURC** and county BZA agendas; **Wisconsin PSC** CPCN dockets; **Minnesota PUC** site permits.
- **Texas:** no state siting for generation, so the useful sources are ERCOT GIS and county commissioner agendas. TDLR registrations appear in Greenlight (`tdlr` enum exists).
- **California CEC:** Opt-in certification (AB 205) docket; **Arizona ACC:** CEC line siting.

### Data center demand (Claude tasks)
- Utility large-load filings and IRP updates (Dominion, Georgia Power, AEP, Entergy), county rezoning and special-use-permit agendas, and state bills. Greenlight covers some of this weekly.
- The `data_center` technology and moratorium signals already exist.

## 5. Claude routine seeds (paste-ready prompts)

Each runs as a scheduled Claude routine with the Supabase connector, like the Greenlight routine. They write only through narrow `bd.*` functions. Add a small ingest function per routine, modeled on `bd.ingest_greenlight`, before enabling it.

### Opposition sweep (weekly; `opposition_sweep`, signal sources `opposition_web` and `opposition_petition`)
```
You are the BD Radar opposition sweep. For each enabled footprint state (select state from bd.footprint where enabled), search the web for news from the last 7 days about organized local opposition to solar, wind, battery storage, transmission or data center projects: new opposition groups, petitions, lawsuits, packed hearings, moratorium proposals. For each item, record title, place (county and state), date, technology, project name if named, developer if named, the source URL, and a one-sentence summary. Skip items already on file (search bd.search_leads by project name first). Load results with select bd.ingest_opposition('<JSON array>'::jsonb). Never invent a URL or a name. Report counts, with no em-dashes.
```

### State docket watch (weekly; `state_docket`)
```
You are the BD Radar docket watcher. Check these siting portals for new filings, hearing notices and decisions in the last 7 days: NY ORES, Ohio OPSB, Michigan PSC (PA 233), Virginia SCC, Wisconsin PSC, Minnesota PUC. For each, record docket number, project name, applicant, county, state, filing type, date and URL. Match to existing projects by name and county via bd.search_leads; load with select bd.ingest_docket('<JSON array>'::jsonb). Report counts, with no em-dashes.
```

### Utility queue census (one-time, then quarterly; feeds the non-RTO plan)
```
For each utility in this list [Duke, Southern Co. (Georgia Power, Alabama Power, Mississippi Power), TVA, Santee Cooper, Dominion SC, FPL, PacifiCorp, NV Energy, APS, SRP, TEP, Xcel PSCo, Idaho Power, PGE, PSE, BPA, El Paso Electric, PNM], find its public generator interconnection queue. Record: URL, format (xlsx, csv, pdf, html), whether login is required, update cadence, and whether rows include county, MW, fuel, queue date, status and developer. Output a markdown table and save it to docs/utility-queues.md. Do not guess; mark anything you could not open.
```

### Developer normalization (one-time, then monthly)
```
List bd.developers with their project counts. Group names that are the same company (NextEra, NextEra Energy, NextEra Energy Resources; Invenergy, Invenergy LLC; Savion, Savion Energy), keeping project-specific LLCs as their own developer with parent_name set to the parent. Propose the merge list for review; after approval, apply it with a bd.merge_developers function (to be written) that repoints projects and leads and keeps known_to_renusa and people links.
```

## 6. Ready-to-paste build prompts for Claude Code

- **MISO:** "Read docs/expansion-playbook.md section 2 and the MISO seed. Build the MISO queue feed: lib/feeds/miso.ts (JSON), run function, cron route (Wednesday 10:00 UTC), Run now entry, migration adding MISO to the staleness exclusions if needed, and tests. Enable the miso_queue source. Open a PR, merge it, and ask me to click Run now; then check bd.source_runs and fix column aliases."
- **SPP, NYISO, ISO-NE, CAISO:** same prompt, swapping the seed. For NYISO, also map `Developer/Interconnection Customer` to developer.
- **ERCOT:** "Build the ERCOT GIS feed from the monthly GIS Report workbook (Project Details - Large Gen tab). Add an ERCOT_API_KEY hook like PJM_API_KEY. Use milestone dates as real activity dates so staleness works for ERCOT."
- **EIA-860M:** "Build a monthly EIA-860M feed: Planned sheet, status code to stage mapping per the playbook, operator as developer, and store latitude and longitude on bd.projects (lat and lng columns exist) so the map uses real points when present. Update lead-map to prefer project coordinates over county centroids."
- **Going national:** "Enable all states in bd.footprint, rescore, and report how the 50+ list changes by state."

## 7. Order of work (recommended)

1. MISO and SPP: largest volume, simple formats.
2. EIA-860M: national developer names and coordinates, which unlocks Access scoring and real map pins.
3. NYISO and ISO-NE: they finish the East, and NYISO names developers.
4. ERCOT GIS: Texas, with developers and milestone dates.
5. Developer normalization and the contact CSV: turns on Access points.
6. PJM new-cycle gap.
7. CAISO, then the non-RTO utility census and the feeds that are clean enough.
8. Opposition sweep and docket watch routines.
