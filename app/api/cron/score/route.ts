import { rpc } from '@/lib/db';
import { runJob } from '@/lib/feeds/run';

export const runtime = 'nodejs';
export const maxDuration = 120;

// Nightly rescore so date-based factors (12-month windows) stay current.
export async function GET(req: Request) {
  return runJob(req, 'scoring', async () => ({ detail: await rpc<Record<string, unknown>>('run_scoring') }));
}
