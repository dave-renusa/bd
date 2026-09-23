# RenUSA BD Radar

Finds early-stage solar, wind, BESS and data center projects that need community
engagement support and turns them into a scored, owned pipeline. Design and
decisions: [docs/handoff_2026-09-23_bd-radar.md](docs/handoff_2026-09-23_bd-radar.md).

## How it fits together

- **Database**: Supabase project `csxvtewzlhigrzvpxtvf`, schema `bd` only. Migrations in
  `supabase/migrations/` (apply in filename order). RLS is on with no policies, so only the
  service role can read or write.
- **Collection (Vercel Cron, `vercel.json`)**: each feed in `lib/feeds/` fetches, parses and
  normalizes, then hands rows to a Postgres function (`bd.ingest_queue`, `bd.ingest_sabin`)
  that diffs, writes `signals`, and upserts `projects`. Every run is logged in `bd.sources`
  and `bd.source_runs` (see `/sources`).
- **Scoring**: `bd.score_lead()` in Postgres, weights in `bd.score_weights`, thresholds in
  `bd.settings`. `bd.run_scoring()` creates missing project leads, rescores everything, and
  moves Signal leads that reach 70 to Qualified (stamping `qualified_at`, which drives the
  daily alert). Runs after each feed and nightly.
- **Web app**: `/` Today, `/pipeline`, `/sources`. Stage, owner and snooze are one click.
- **Claude tasks** (not in this repo yet): enrichment, opposition sweep, Greenlight parsing,
  outreach drafts. They read and write `bd.*` through the Supabase REST API with the service
  key, using the `Accept-Profile: bd` / `Content-Profile: bd` headers.

## Cron schedule (UTC)

| Route | Schedule | Eastern |
| --- | --- | --- |
| `/api/cron/pjm` | Mon 10:00 | 6 AM EDT / 5 AM EST |
| `/api/cron/sabin` | Tue 10:00 | 6 AM EDT / 5 AM EST |
| `/api/cron/score` | daily 10:30 | 6:30 AM EDT |
| `/api/cron/daily-alert` | daily 11:00 | 7 AM EDT / 6 AM EST |

Vercel Cron runs in UTC, so the alert lands at 7 AM only during daylight time. Run any job by
hand: `curl -H "Authorization: Bearer $CRON_SECRET" https://bd.renusa.report/api/cron/pjm`.

## Local

```
cp .env.example .env.local   # fill in the service key and CRON_SECRET
npm install
npm run dev
npm test                     # feed parser tests
```

Imports (run locally with the env vars set):

```
npm run import:people -- contacts.csv            # RenUSA contact list into bd.people
npm run import:sabin -- restrictions.xlsx contested.xlsx   # manual Sabin load
```

## Known gaps

- The PJM public export has no developer column. Queue projects arrive without a developer
  until enrichment resolves one, so they earn no Access points on their own.
- Without people data, the maximum score is 65 (Fit 20 + Stage 20 + Pain 25), so nothing
  alerts at 70 until the contact list is imported or developers are marked `known_to_renusa`.
- Sabin column names and download links are matched heuristically; check the counts on
  `/sources` after the first run.
