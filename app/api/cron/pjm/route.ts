import { runJob, runPjm } from '@/lib/feeds/run';

export const runtime = 'nodejs';
export const maxDuration = 300;

// Weekly (vercel.json). Also callable by hand with the cron secret.
export async function GET(req: Request) {
  return runJob(req, 'pjm_queue', runPjm);
}
