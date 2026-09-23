import { db } from '@/lib/db';
import { alertRecipients, dailyAlertHtml, sendEmail, type AlertLead } from '@/lib/alerts';
import { runJob } from '@/lib/feeds/run';

export const runtime = 'nodejs';
export const maxDuration = 60;

// Daily at 7:00 AM Eastern (vercel.json uses UTC, see README). Emails leads
// that crossed the qualify threshold in the last 24 hours and were not
// already alerted. Sends nothing when nothing crossed.
export async function GET(req: Request) {
  return runJob(req, 'daily_alert', async () => {
    const since = new Date(Date.now() - 24 * 3600 * 1000).toISOString();
    const today = new Date().toISOString().slice(0, 10);
    const { data: leads, error } = await db()
      .from('lead_view')
      .select('id, display_name, score, subject_technology, subject_state, county_name, place_name, why_now, latest_headline, owner, snoozed_until')
      .gte('qualified_at', since)
      .order('score', { ascending: false });
    if (error) throw new Error(error.message);

    const { data: sent } = await db().from('alerts').select('lead_id').eq('kind', 'daily')
      .in('lead_id', (leads ?? []).map((l) => l.id));
    const already = new Set((sent ?? []).map((a) => a.lead_id));
    const fresh = (leads ?? []).filter((l) => !already.has(l.id) && !(l.snoozed_until && l.snoozed_until > today)) as AlertLead[];

    if (fresh.length === 0) return { rows: 0, detail: { sent: false, reason: 'nothing crossed the threshold' } };

    const to = await alertRecipients();
    if (to.length === 0) throw new Error('No alert recipients configured');
    const site = process.env.SITE_URL || 'https://bd.renusa.report';
    const subject = `BD Radar: ${fresh.length} new lead${fresh.length === 1 ? '' : 's'} at 70+ (${fresh[0].display_name}${fresh.length > 1 ? ' and more' : ''})`;
    const id = await sendEmail(to, subject, dailyAlertHtml(fresh, site));

    const { error: logError } = await db().from('alerts')
      .insert(fresh.map((l) => ({ lead_id: l.id, kind: 'daily', recipients: to, created_by: 'cron:daily_alert' })));
    if (logError) throw new Error(`email sent (${id}) but alert log failed: ${logError.message}`);
    return { rows: fresh.length, detail: { sent: true, resend_id: id, recipients: to.length } };
  });
}
