import LeadControls from './lead-controls';
import { activityLabel, linkable, stageLabel, techLabel, type LeadRow } from '@/lib/leads';

const FACTORS: { key: 'fit' | 'stage' | 'pain' | 'access' | 'competition'; label: string; max: number }[] = [
  { key: 'fit', label: 'Fit', max: 20 },
  { key: 'stage', label: 'Timing', max: 20 },
  { key: 'pain', label: 'Pain', max: 25 },
  { key: 'access', label: 'Access', max: 25 },
  { key: 'competition', label: 'Competition', max: 10 },
];

function size(l: LeadRow): string | null {
  if (l.mw_ac) return `${Number(l.mw_ac).toLocaleString()} MW`;
  if (l.mw_storage) return `${Number(l.mw_storage).toLocaleString()} MW storage`;
  if (l.acres) return `~${Number(l.acres).toLocaleString()} acres`;
  return null;
}

export default function LeadCard({ lead, owners, qualify }: { lead: LeadRow; owners: string[]; qualify: number }) {
  const b = lead.score_breakdown ?? {};
  const where = [lead.place_name, lead.county_name ?? lead.subject_state].filter(Boolean).join(', ');
  const tone = lead.score >= qualify ? '' : lead.score >= 50 ? ' mid' : ' low';
  const chips = [
    techLabel(lead.subject_technology),
    size(lead),
    lead.project_stage ? `Permitting: ${stageLabel(lead.project_stage)}` : null,
    lead.iso && lead.queue_id ? `${lead.iso} ${lead.queue_id}` : null,
  ].filter(Boolean) as string[];

  return (
    <article className="card" id={`lead-${lead.id}`}>
      <div className={`score${tone}`}><b>{lead.score}</b><span>score</span></div>
      <div>
        <h3 className="card-title">{lead.display_name}</h3>
        {where && <p className="card-sub">{where}</p>}
        {lead.kind === 'project' && (lead.developer_name
          ? <p className="card-sub">Developer: {lead.developer_name}{lead.developer_parent ? ` (${lead.developer_parent})` : ''}</p>
          : <p className="card-sub unknown">Developer not identified yet</p>)}
        <div className="chips">
          {chips.map((c) => <span key={c} className="chip">{c}</span>)}
          {activityLabel(lead) && (
            <span className={`chip${b.stale ? ' stale' : ''}`}>{activityLabel(lead)}</span>
          )}
          {lead.risk_tier != null && lead.risk_tier >= 3 && (
            <span className="chip risk">County risk {lead.risk_tier}/5</span>
          )}
        </div>

        {lead.why_now
          ? <p className="why">{lead.why_now}</p>
          : <p className="why pending">Why now: awaiting enrichment.</p>}
        {lead.latest_headline && (
          <p className="headline">
            Latest signal: {linkable(lead.latest_url)
              ? <a href={linkable(lead.latest_url)!} target="_blank" rel="noreferrer">{lead.latest_headline}</a>
              : lead.latest_headline}
            {lead.last_signal_at && ` (${new Date(lead.last_signal_at).toLocaleDateString('en-US', { month: 'short', day: 'numeric' })})`}
          </p>
        )}

        <div className="bars">
          {FACTORS.map((f) => {
            const v = Number(b[f.key] ?? 0);
            const neg = f.key === 'competition';
            const pct = Math.min(100, (Math.abs(v) / f.max) * 100);
            return (
              <div key={f.key}>
                <div className="bar-label"><span>{f.label}</span><span>{v}{neg ? '' : `/${f.max}`}</span></div>
                <div className={`bar${neg ? ' neg' : ''}`}><i style={{ width: `${pct}%` }} /></div>
              </div>
            );
          })}
        </div>
        {b.reasons && b.reasons.length > 0 && (
          <details className="reasons">
            <summary>Why this score</summary>
            <ul>
              {b.reasons.map((r) => (
                <li key={r.key}>{r.points > 0 ? `+${r.points}` : r.points} {r.label}{r.detail ? `: ${r.detail}` : ''}</li>
              ))}
            </ul>
          </details>
        )}

        {lead.next_action && (
          <p className="next"><strong>Next:</strong> {lead.next_action}
            {lead.next_action_date && ` (by ${lead.next_action_date})`}</p>
        )}
        <LeadControls id={lead.id} stage={lead.stage} closedReason={lead.closed_reason} owner={lead.owner} owners={owners} />
      </div>
    </article>
  );
}
