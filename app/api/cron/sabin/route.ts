import { runJob, runSabin } from '@/lib/feeds/run';

export const runtime = 'nodejs';
export const maxDuration = 300;

// Weekly check; Sabin updates monthly and unchanged rows are deduped.
export async function GET(req: Request) {
  return runJob(req, 'sabin', runSabin);
}
