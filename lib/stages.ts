// Shared with client components, so no server imports here.
export const LEAD_STAGES = ['New', 'Working', 'Closed', 'Watch'] as const;
export type LeadStage = (typeof LEAD_STAGES)[number];

/** What each of our sales stages means. Shown in the stage guide. */
export const LEAD_STAGE_HELP: Record<LeadStage, string> = {
  New: 'Created automatically from a feed; nobody has picked it up yet.',
  Working: 'Someone is on it: reviewing, reaching out, talking or proposing.',
  Closed: 'Done: won (engaged), lost, or dead project (stalled, canceled or not worth pursuing). Hidden from Home and, by default, from Pipeline.',
  Watch: 'Not now, keep an eye on it. Set automatically for projects already built.',
};

export const CLOSED_REASONS = ['won', 'lost', 'dead'] as const;
export type ClosedReason = (typeof CLOSED_REASONS)[number];

/** Where a project is in permitting. Set by the feeds, not by us. */
export const PROJECT_STAGES: { key: string; label: string; help: string }[] = [
  { key: 'queue', label: 'In grid queue', help: 'Filed to connect to the grid; no permit activity seen yet.' },
  { key: 'state_prefiling', label: 'State pre-filing', help: 'Early filing or notice with a state siting board or utility commission.' },
  { key: 'local_preapp', label: 'Local pre-application', help: 'Early meetings or pre-application with the town or county.' },
  { key: 'filed', label: 'Permit filed', help: 'Permit, rezoning or registration application on file.' },
  { key: 'hearing', label: 'Hearing scheduled', help: 'A public hearing or vote is coming up.' },
  { key: 'contested', label: 'Contested', help: 'Organized opposition, litigation or a contested hearing.' },
  { key: 'tabled', label: 'Tabled', help: 'Decision postponed or paused.' },
  { key: 'denied', label: 'Denied', help: 'Permit or rezoning denied.' },
  { key: 'moratorium_blocked', label: 'Blocked by moratorium', help: 'A local moratorium or ban stops it for now.' },
  { key: 'approved', label: 'Approved', help: 'Approved, under construction or operating.' },
  { key: 'withdrawn', label: 'Withdrawn', help: 'Withdrawn or canceled by the developer.' },
];

const PROJECT_STAGE_LABELS = Object.fromEntries(PROJECT_STAGES.map((s) => [s.key, s.label]));

export const projectStageLabel = (s: string | null) =>
  s ? PROJECT_STAGE_LABELS[s] ?? s.replace(/_/g, ' ') : '';
