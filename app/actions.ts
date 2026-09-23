'use server';

import { revalidatePath } from 'next/cache';
import { db } from '@/lib/db';
import { CLOSED_REASONS, LEAD_STAGES, type ClosedReason, type LeadStage } from '@/lib/stages';

async function update(id: string, patch: Record<string, unknown>) {
  const { error } = await db().from('leads').update(patch).eq('id', id);
  if (error) throw new Error(error.message);
  revalidatePath('/');
  revalidatePath('/pipeline');
}

/** Closed needs a reason: won or lost. */
export async function setStage(id: string, stage: LeadStage, reason?: ClosedReason) {
  if (!LEAD_STAGES.includes(stage)) throw new Error('invalid stage');
  if (stage === 'Closed' && !CLOSED_REASONS.includes(reason as ClosedReason)) throw new Error('closed needs won or lost');
  await update(id, {
    stage,
    closed_reason: stage === 'Closed' ? reason : null,
    stage_changed_at: new Date().toISOString(),
  });
}

export async function setOwner(id: string, owner: string) {
  await update(id, { owner: owner.trim() || null });
}

export async function snooze(id: string, days: number) {
  const until = new Date(Date.now() + days * 24 * 3600 * 1000).toISOString().slice(0, 10);
  await update(id, { snoozed_until: until });
}
