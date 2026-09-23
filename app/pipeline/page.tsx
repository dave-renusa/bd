import { LEAD_STAGES, SEARCH_LIMIT, lastActivity, linkable, pipeline, owners, stageLabel, techLabel } from '@/lib/leads';
import { STATE_CODES } from '@/lib/states';
import LeadControls from '../lead-controls';
import LeadMap, { type MapPoint } from './lead-map';
import CENTROIDS from '@/lib/county-centroids.json';
import StageGuide from '../stage-guide';

export const dynamic = 'force-dynamic';

const TECHS = ['solar', 'wind', 'bess', 'solar_bess', 'data_center', 'transmission', 'other'];
const STATES = Object.entries(STATE_CODES).map(([name, code]) => ({
  code, name: name.replace(/\b\w/g, (c) => c.toUpperCase()),
})).sort((a, b) => a.name.localeCompare(b.name));
const KINDS = [
  { value: 'project', label: 'Projects' },
  { value: 'jurisdiction', label: 'Places (moratoria, rules)' },
];

type Params = { q?: string; stage?: string; owner?: string; tech?: string; state?: string; kind?: string; min?: string; view?: string };

const COORDS = CENTROIDS as unknown as Record<string, [number, number]>;

/** Same query string with a different view. */
function viewHref(sp: Params, view: 'list' | 'map') {
  const q = new URLSearchParams();
  for (const [k, v] of Object.entries(sp)) if (v && k !== 'view') q.set(k, v);
  if (view === 'map') q.set('view', 'map');
  const s = q.toString();
  return `/pipeline${s ? `?${s}` : ''}`;
}

export default async function Pipeline({ searchParams }: { searchParams: Promise<Params> }) {
  const sp = await searchParams;
  const searching = !!(sp.q?.trim() || sp.state || sp.tech || sp.kind);
  // Browsing defaults to 50+; a search shows every score unless a minimum is set.
  const min = sp.min !== undefined && sp.min !== '' ? Number(sp.min) : searching ? 0 : 50;
  const [rows, ownerList] = await Promise.all([
    pipeline({ q: sp.q, stage: sp.stage, owner: sp.owner, tech: sp.tech, state: sp.state?.toUpperCase(), kind: sp.kind, min }),
    owners(),
  ]);

  const mapView = sp.view === 'map';
  const points: MapPoint[] = [];
  let unmapped = 0;
  if (mapView) {
    for (const l of rows) {
      const c = l.subject_fips ? COORDS[l.subject_fips] : undefined;
      if (!c) { unmapped++; continue; }
      points.push({
        id: l.id, lat: c[0], lon: c[1], name: l.display_name, score: l.score,
        tech: techLabel(l.subject_technology) + (l.mw_ac ? `, ${Number(l.mw_ac).toLocaleString()} MW` : ''),
        where: [l.place_name, l.county_name ?? l.subject_state].filter(Boolean).join(', '),
        developer: l.kind === 'project'
          ? (l.developer_name ? `Developer: ${l.developer_name}${l.developer_parent ? ` (${l.developer_parent})` : ''}` : 'Developer not identified yet')
          : null,
        permitting: stageLabel(l.project_stage), lastActivity: lastActivity(l.score_breakdown),
        stale: !!l.score_breakdown?.stale, url: linkable(l.latest_url),
      });
    }
  }

  return (
    <>
      <h1>Pipeline and search</h1>
      <form className="filters section" method="get">
        {mapView && <input type="hidden" name="view" value="map" />}
        <label>Keywords
          <input type="search" name="q" defaultValue={sp.q ?? ''} placeholder="Name, developer, county, setback..." />
        </label>
        <label>State
          <select name="state" defaultValue={sp.state?.toUpperCase() ?? ''}>
            <option value="">Any</option>
            {STATES.map((s) => <option key={s.code} value={s.code}>{s.name}</option>)}
          </select>
        </label>
        <label>Technology
          <select name="tech" defaultValue={sp.tech ?? ''}>
            <option value="">Any</option>
            {TECHS.map((t) => <option key={t} value={t}>{techLabel(t)}</option>)}
          </select>
        </label>
        <label>Type
          <select name="kind" defaultValue={sp.kind ?? ''}>
            <option value="">Any</option>
            {KINDS.map((k) => <option key={k.value} value={k.value}>{k.label}</option>)}
          </select>
        </label>
        <label>Our stage
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
        <label>Min score
          <input type="number" name="min" defaultValue={min} min={0} max={100} style={{ minWidth: 70, width: 70 }} />
        </label>
        <div className="actions">
          <button className="primary" type="submit">Search</button>
          {searching && <a className="button" href="/pipeline">Clear</a>}
        </div>
      </form>
      <p className="meta">
        Keywords match the lead name, developer, place and the text of every signal, so &ldquo;setback&rdquo; finds
        leads whose Sabin or Greenlight write-up mentions a setback. All words must match.
      </p>
      <StageGuide />

      <div className="view-bar section">
        <nav className="segmented" aria-label="View">
          <a href={viewHref(sp, 'list')} className={mapView ? undefined : 'on'} aria-current={mapView ? undefined : 'page'}>List</a>
          <a href={viewHref(sp, 'map')} className={mapView ? 'on' : undefined} aria-current={mapView ? 'page' : undefined}>Map</a>
        </nav>
      <p className="meta">
        {rows.length} lead{rows.length === 1 ? '' : 's'}{min > 0 ? `, score ${min}+` : ''}{sp.stage ? '' : ', closed leads hidden'}, highest score first
        {rows.length === SEARCH_LIMIT ? ` (first ${SEARCH_LIMIT}; narrow the search to see the rest)` : ''}.
        {mapView && unmapped > 0 && ` ${unmapped} without a county (statewide or federal) are not on the map.`}
      </p>
      </div>
      {mapView ? (
        <>
          <LeadMap points={points} />
          <p className="meta map-legend">
            <span className="dot high" /> 70+ <span className="dot mid" /> 50 to 69 <span className="dot low" /> under 50.
            Faded dots are stale. Leads sit at their county&apos;s center. Click a dot for details; click the map to zoom with the scroll wheel.
          </p>
        </>
      ) : (
      <div className="table-wrap">
        <table className="grid">
          <thead>
            <tr><th className="num">Score</th><th>Lead</th><th>Tech</th><th>Permitting</th><th>Last activity</th><th>Our stage and owner</th></tr>
          </thead>
          <tbody>
            {rows.map((l) => (
              <tr key={l.id}>
                <td className="num"><span className={`score-pill${l.score >= 70 ? ' high' : l.score >= 50 ? ' mid' : ''}`}>{l.score}</span></td>
                <td>{linkable(l.latest_url)
                  ? <a href={linkable(l.latest_url)!} target="_blank" rel="noreferrer">{l.display_name}</a>
                  : l.display_name}
                  <div className="meta">{[l.place_name, l.county_name ?? l.subject_state].filter(Boolean).join(', ')}</div>
                  {l.kind === 'project' && (l.developer_name
                    ? <div className="meta">Developer: {l.developer_name}{l.developer_parent ? ` (${l.developer_parent})` : ''}</div>
                    : <div className="meta unknown">Developer not identified yet</div>)}</td>
                <td>{techLabel(l.subject_technology)}{l.mw_ac ? <div className="meta">{Number(l.mw_ac).toLocaleString()} MW</div> : null}</td>
                <td>{stageLabel(l.project_stage)}</td>
                <td className="meta">{lastActivity(l.score_breakdown)}{l.score_breakdown?.stale && <div><span className="status status-none">Stale</span></div>}</td>
                <td><LeadControls compact id={l.id} stage={l.stage} closedReason={l.closed_reason} owner={l.owner} owners={ownerList} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      )}
    </>
  );
}
