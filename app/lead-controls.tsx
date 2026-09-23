'use client';

import { useTransition } from 'react';
import { setOwner, setStage, snooze } from './actions';
import type { ClosedReason, LeadStage } from '@/lib/stages';

// Closed is split into won and lost so the reason is recorded with the stage.
const OPTIONS: { value: string; label: string; stage: LeadStage; reason?: ClosedReason }[] = [
  { value: 'New', label: 'New', stage: 'New' },
  { value: 'Working', label: 'Working', stage: 'Working' },
  { value: 'Closed:won', label: 'Closed: won', stage: 'Closed', reason: 'won' },
  { value: 'Closed:lost', label: 'Closed: lost', stage: 'Closed', reason: 'lost' },
  { value: 'Closed:dead', label: 'Closed: dead project', stage: 'Closed', reason: 'dead' },
  { value: 'Watch', label: 'Watch', stage: 'Watch' },
];

export default function LeadControls({ id, stage, closedReason, owner, owners }: {
  id: string; stage: LeadStage; closedReason?: string | null; owner: string | null; owners: string[];
}) {
  const [pending, start] = useTransition();
  const ownerList = owner && !owners.includes(owner) ? [...owners, owner] : owners;
  const current = stage === 'Closed' ? `Closed:${closedReason ?? 'won'}` : stage;
  return (
    <div className="controls" aria-busy={pending}>
      <label>
        Our stage
        <select defaultValue={current} disabled={pending}
          onChange={(e) => {
            const o = OPTIONS.find((x) => x.value === e.target.value);
            if (o) start(() => setStage(id, o.stage, o.reason));
          }}>
          {OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
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
      {pending && <span className="saving">Saving...</span>}
    </div>
  );
}
