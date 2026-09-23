// Loads Sabin files downloaded by hand, for when the cron cannot find them.
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... npm run import:sabin -- restrictions.xlsx contested.xlsx
// Pass "-" to skip one of the two files.
import { readFileSync } from 'node:fs';
import { rpc } from '../lib/db';
import { readSheet } from '../lib/sheets';
import { normalizeContested, normalizeRestrictions } from '../lib/feeds/sabin';

async function main() {
  const [rFile, cFile] = process.argv.slice(2);
  if (!rFile || !cFile) throw new Error('usage: npm run import:sabin -- <restrictions file|-> <contested file|->');
  const load = async (f: string) => (f === '-' ? [] : readSheet(readFileSync(f), ['State', 'County']));
  const r = normalizeRestrictions(await load(rFile));
  const c = normalizeContested(await load(cFile));
  console.log(`Parsed ${r.length} restrictions, ${c.length} contested projects.`);
  const started = new Date().toISOString();
  const result = await rpc('ingest_sabin', { p_restrictions: r, p_contested: c });
  await rpc('record_source_run', { p_key: 'sabin', p_status: 'ok', p_row_count: r.length + c.length, p_detail: { manual: true, ...(result as object) }, p_started_at: started });
  console.log(result);
  console.log('Rescore:', await rpc('run_scoring'));
}

main().catch((e) => { console.error(e); process.exit(1); });
