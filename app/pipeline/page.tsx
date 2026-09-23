import { LEAD_STAGES, pipeline, owners, stageLabel, techLabel } from '@/lib/leads';
import LeadControls from '../lead-controls';

export const dynamic = 'force-dynamic';

const TECHS = ['solar', 'wind', 'bess', 'solar_bess', 'data_center', 'transmission', 'other'];

export default async function Pipeline({ searchParams }: {
  searchParams: Promise<{ stage?: string; owner?: string; tech?: string; state?: string; min?: string }>;
}) {
  const sp = await searchParams;
  const min = sp.min === undefined || sp.min === '' ? 50 : Number(sp.min);
  const [rows, ownerList] = await Promise.all([
    pipeline({ stage: sp.stage, owner: sp.owner, tech: sp.tech, state: sp.state?.toUpperCase(), min }),
    owners(),
  ]);

  return (
    <>
      <h1>Pipeline</h1>
      <form className="filters section" method="get">
        <label>Stage
          <select name="stage" defaultValue={sp.stage ?? ''}>
            <option value="">Any</option>
            {LEAD_STAGES.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
        </label>
        <label>Owner
          <select name="owner" defaultValue={sp.owner ?? ''}>
            <option value="">Any</option>
            <option value="_none">Unassigned</option>
            {ownerList.map((o) => <option key={o} value={o}>{o}</option>)}
          </select>
        </label>
        <label>Technology
          <select name="tech" defaultValue={sp.tech ?? ''}>
            <option value="">Any</option>
            {TECHS.map((t) => <option key={t} value={t}>{techLabel(t)}</option>)}
          </select>
        </label>
        <label>State
          <input type="text" name="state" defaultValue={sp.state ?? ''} placeholder="VA" maxLength={2} style={{ minWidth: 60, width: 60 }} />
        </label>
        <label>Min score
          <input type="number" name="min" defaultValue={min} min={0} max={100} style={{ minWidth: 70, width: 70 }} />
        </label>
        <button className="primary" type="submit">Filter</button>
      </form>

      <p className="meta">{rows.length} lead{rows.length === 1 ? '' : 's'}, highest score first{rows.length === 500 ? ' (first 500)' : ''}.</p>
      <div className="table-wrap">
        <table className="grid">
          <thead>
            <tr><th className="num">Score</th><th>Lead</th><th>Tech</th><th>Where</th><th>Project stage</th><th>Latest signal</th><th>Stage and owner</th></tr>
          </thead>
          <tbody>
            {rows.map((l) => (
              <tr key={l.id}>
                <td className="num"><strong>{l.score}</strong></td>
                <td><a href={`/?all=1#lead-${l.id}`}>{l.display_name}</a>
                  {l.developer_name && <div className="meta">{l.developer_name}</div>}</td>
                <td>{techLabel(l.subject_technology)}{l.mw_ac ? <div className="meta">{Number(l.mw_ac).toLocaleString()} MW</div> : null}</td>
                <td>{[l.place_name, l.county_name ?? l.subject_state].filter(Boolean).join(', ')}</td>
                <td>{stageLabel(l.project_stage)}</td>
                <td className="meta">{l.last_signal_at ? new Date(l.last_signal_at).toLocaleDateString('en-US') : ''}</td>
                <td style={{ minWidth: 300 }}><LeadControls id={l.id} stage={l.stage} owner={l.owner} owners={ownerList} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}
