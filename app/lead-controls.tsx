'use client';

import { useTransition } from 'react';
import { setOwner, setStage, snooze } from './actions';
import { LEAD_STAGES, type LeadStage } from '@/lib/stages';

export default function LeadControls({ id, stage, owner, owners }: {
  id: string; stage: LeadStage; owner: string | null; owners: string[];
}) {
  const [pending, start] = useTransition();
  const ownerList = owner && !owners.includes(owner) ? [...owners, owner] : owners;
  return (
    <div className="controls" aria-busy={pending}>
      <label>
        Our stage
        <select defaultValue={stage} disabled={pending}
          onChange={(e) => { const v = e.target.value as LeadStage; start(() => setStage(id, v)); }}>
          {LEAD_STAGES.map((s) => <option key={s} value={s}>{s}</option>)}
        </select>
      </label>
      <label>
        Owner
        <select defaultValue={owner ?? ''} disabled={pending}
          onChange={(e) => { const v = e.target.value; start(() => setOwner(id, v)); }}>
          <option value="">Unassigned</option>
          {ownerList.map((o) => <option key={o} value={o}>{o}</option>)}
        </select>
      </label>
      <button type="button" disabled={pending} onClick={() => start(() => snooze(id, 14))}>
        Snooze 2 weeks
      </button>
      {pending && <span className="meta">Saving...</span>}
    </div>
  );
}
