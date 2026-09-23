import { NextResponse } from 'next/server';
import { rpc } from '@/lib/db';
import { executeJob, runPjm, runSabin } from '@/lib/feeds/run';

export const runtime = 'nodejs';
export const maxDuration = 300;

// Manual "Run now" for the Sources page. Not under /api/cron, so proxy.ts
// requires the site key cookie like every other page.
const JOBS = {
  pjm: { key: 'pjm_queue', job: runPjm },
  sabin: { key: 'sabin', job: runSabin },
  score: { key: 'scoring', job: async () => ({ detail: await rpc<Record<string, unknown>>('run_scoring') }) },
} as const;

export async function GET(req: Request, { params }: { params: Promise<{ job: string }> }) {
  const { job } = await params;
  const entry = JOBS[job as keyof typeof JOBS];
  if (!entry) return NextResponse.json({ error: `unknown job ${job}` }, { status: 404 });
  const res = await executeJob(entry.key, entry.job);
  if (new URL(req.url).searchParams.get('back')) {
    return NextResponse.redirect(new URL(`/sources?ran=${job}`, req.url), 303);
  }
  return res;
}
