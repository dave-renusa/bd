import { LEAD_STAGES, LEAD_STAGE_HELP, PROJECT_STAGES } from '@/lib/stages';

/** Explains the two stage fields: ours (sales) and the project's (permitting). */
export default function StageGuide() {
  return (
    <details className="guide">
      <summary>What the stages mean</summary>
      <div className="guide-cols">
        <div>
          <h3>Our stage</h3>
          <p className="meta">Where we are with the lead. You set this with the Our stage menu.</p>
          <dl>
            {LEAD_STAGES.map((s) => (
              <div key={s}><dt>{s}</dt><dd>{LEAD_STAGE_HELP[s]}</dd></div>
            ))}
          </dl>
        </div>
        <div>
          <h3>Permitting</h3>
          <p className="meta">Where the project is with regulators. The feeds set this. It drives the Timing part of the score.</p>
          <dl>
            {PROJECT_STAGES.map((s) => (
              <div key={s.key}><dt>{s.label}</dt><dd>{s.help}</dd></div>
            ))}
          </dl>
        </div>
      </div>
    </details>
  );
}
