import { db } from './db';

export async function alertRecipients(): Promise<string[]> {
  const fromEnv = (process.env.ALERT_RECIPIENTS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  if (fromEnv.length) return fromEnv;
  const { data } = await db().from('settings').select('value').eq('key', 'alert_recipients').maybeSingle();
  return Array.isArray(data?.value) ? (data!.value as string[]) : [];
}

/** Sends through the Resend REST API. Never used for outreach, only internal alerts. */
export async function sendEmail(to: string[], subject: string, html: string): Promise<string> {
  const key = process.env.RESEND_API_KEY;
  if (!key) throw new Error('RESEND_API_KEY is not set');
  const from = process.env.ALERT_FROM || 'BD Radar <onboarding@resend.dev>';
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from, to, subject, html }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`Resend ${res.status}: ${JSON.stringify(body).slice(0, 500)}`);
  return (body as { id?: string }).id ?? '';
}

const esc = (s: unknown) =>
  String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

export interface AlertLead {
  id: string;
  display_name: string;
  score: number;
  subject_technology: string | null;
  subject_state: string | null;
  county_name: string | null;
  place_name: string | null;
  why_now: string | null;
  latest_headline: string | null;
  owner: string | null;
}

export function dailyAlertHtml(leads: AlertLead[], siteUrl: string): string {
  const rows = leads
    .map((l) => {
      const where = [l.place_name, l.county_name ?? l.subject_state].filter(Boolean).join(', ');
      const tech = (l.subject_technology ?? '').replace('_', ' + ');
      return `
      <tr><td style="padding:14px 0;border-bottom:1px solid #E3DED3">
        <div style="font:600 13px Arial,sans-serif;color:#B03030">${esc(l.score)} / 100</div>
        <div style="font:700 17px Arial,sans-serif;color:#0A2240;margin:2px 0">
          <a href="${esc(siteUrl)}/?lead=${esc(l.id)}" style="color:#0A2240;text-decoration:none">${esc(l.display_name)}</a></div>
        <div style="font:13px Arial,sans-serif;color:#5A6273">${esc(tech)}${tech && where ? ' · ' : ''}${esc(where)}${l.owner ? ` · Owner: ${esc(l.owner)}` : ''}</div>
        <div style="font:14px Arial,sans-serif;color:#1E2533;margin-top:6px">${esc(l.why_now ?? l.latest_headline ?? '')}</div>
      </td></tr>`;
    })
    .join('');
  return `<div style="background:#F5F3EE;padding:24px">
  <table width="100%" style="max-width:640px;margin:0 auto;background:#fff;border-top:4px solid #B03030" cellpadding="0" cellspacing="0">
    <tr><td style="background:#0A2240;padding:16px 24px;border-bottom:2px solid #C8963C">
      <div style="font:700 20px Arial,sans-serif;color:#fff;letter-spacing:1px">BD RADAR</div>
      <div style="font:13px Arial,sans-serif;color:#D5DAE3">${leads.length} lead${leads.length === 1 ? '' : 's'} crossed 70 in the last 24 hours</div>
    </td></tr>
    <tr><td style="padding:4px 24px 20px"><table width="100%" cellpadding="0" cellspacing="0">${rows}</table>
      <p style="font:13px Arial,sans-serif;color:#5A6273;margin-top:16px"><a href="${esc(siteUrl)}" style="color:#0A2240">Open BD Radar</a></p>
    </td></tr>
  </table></div>`;
}
