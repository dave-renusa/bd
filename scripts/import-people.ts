// Imports the RenUSA contact list into bd.people.
//   SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... npm run import:people -- contacts.csv
// Recognized columns (any casing): Full Name (or First Name + Last Name), Company,
// Title, Email, LinkedIn, Owner (Dave | Kate | Ben | other), Strength (1 to 3), Notes.
// Re-running with an updated file updates people instead of duplicating them.
import { readFileSync } from 'node:fs';
import { rpc } from '../lib/db';
import { columnPicker, readSheet, toNumber, toText } from '../lib/sheets';

async function main() {
  const file = process.argv[2];
  if (!file) throw new Error('usage: npm run import:people -- <file.csv|file.xlsx>');
  const rows = await readSheet(readFileSync(file), ['Full Name', 'Name', 'First Name']);
  const col = columnPicker(rows[0]);
  const people = rows.map((r) => {
    const full = toText(col(r, ['Full Name', 'Name', 'Contact']))
      ?? [toText(col(r, ['First Name', 'First'])), toText(col(r, ['Last Name', 'Last']))].filter(Boolean).join(' ');
    const strength = toNumber(col(r, ['Strength', 'Relationship Strength', 'Relationship']));
    return {
      full_name: full,
      current_company: toText(col(r, ['Company', 'Current Company', 'Organization', 'Employer'])),
      current_title: toText(col(r, ['Title', 'Current Title', 'Job Title', 'Position'])),
      email: toText(col(r, ['Email', 'Email Address', 'E-mail'])),
      linkedin_url: toText(col(r, ['LinkedIn', 'LinkedIn URL', 'Linkedin Profile'])),
      relationship_owner: toText(col(r, ['Owner', 'Relationship Owner', 'RenUSA Contact'])),
      relationship_strength: strength && strength >= 1 && strength <= 3 ? Math.round(strength) : null,
      notes: toText(col(r, ['Notes', 'Note'])),
    };
  }).filter((p) => p.full_name);
  let total = 0;
  for (let i = 0; i < people.length; i += 400) {
    const res = await rpc<{ upserted: number }>('import_people', { p_rows: people.slice(i, i + 400) });
    total += res.upserted;
  }
  console.log(`Imported ${total} of ${rows.length} rows.`);
  console.log('Rescore:', await rpc('run_scoring'));
}

main().catch((e) => { console.error(e); process.exit(1); });
