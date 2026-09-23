'use client';

import 'leaflet/dist/leaflet.css';
import { useEffect, useRef } from 'react';

export interface MapPoint {
  id: string; lat: number; lon: number; name: string; score: number; tech: string;
  where: string; permitting: string; lastActivity: string | null; stale: boolean; url: string | null;
}

const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]!);

// Same tiers as the score pills: 70+ navy, 50 to 69 mid navy, under 50 muted.
const tone = (score: number) =>
  score >= 70 ? { fill: '#0A2240', r: 9 } : score >= 50 ? { fill: '#2C4A73', r: 7 } : { fill: '#9AA3B2', r: 5 };

/** Leaflet map of leads at their county centers. Leads sharing a county fan out slightly. */
export default function LeadMap({ points }: { points: MapPoint[] }) {
  const el = useRef<HTMLDivElement>(null);

  useEffect(() => {
    let map: import('leaflet').Map | undefined;
    let cancelled = false;
    (async () => {
      const L = await import('leaflet');
      if (cancelled || !el.current) return;
      map = L.map(el.current, { zoomControl: true, scrollWheelZoom: false, worldCopyJump: true });
      L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
        maxZoom: 12, minZoom: 3,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      }).addTo(map);
      // Scroll-zoom only after a click, so the page still scrolls past the map.
      map.on('click', () => map?.scrollWheelZoom.enable());
      map.on('mouseout', () => map?.scrollWheelZoom.disable());

      const seen = new Map<string, number>();
      const markers: import('leaflet').CircleMarker[] = [];
      // Draw low scores first so the strongest leads sit on top.
      for (const p of [...points].sort((a, b) => a.score - b.score)) {
        const key = `${p.lat},${p.lon}`;
        const n = seen.get(key) ?? 0;
        seen.set(key, n + 1);
        const angle = n * 2.4; const dist = n === 0 ? 0 : 0.06 * Math.sqrt(n);
        const t = tone(p.score);
        const m = L.circleMarker([p.lat + dist * Math.sin(angle), p.lon + dist * Math.cos(angle)], {
          radius: t.r, color: '#FFFFFF', weight: 1.5, fillColor: t.fill, fillOpacity: p.stale ? 0.45 : 0.9,
        });
        const title = p.url
          ? `<a href="${esc(p.url)}" target="_blank" rel="noreferrer">${esc(p.name)}</a>`
          : esc(p.name);
        m.bindPopup(
          `<div class="map-pop"><div class="map-pop-score">${p.score}</div><div>` +
          `<strong>${title}</strong><div class="map-pop-sub">${esc(p.where)}</div>` +
          `<div class="map-pop-meta">${esc([p.tech, p.permitting].filter(Boolean).join(' · '))}</div>` +
          (p.lastActivity ? `<div class="map-pop-meta">${p.stale ? 'Stale: last' : 'Last'} activity ${esc(p.lastActivity)}</div>` : '') +
          `</div></div>`,
        );
        m.bindTooltip(esc(p.name), { direction: 'top', offset: [0, -6] });
        m.addTo(map);
        markers.push(m);
      }
      if (markers.length) map.fitBounds(L.featureGroup(markers).getBounds().pad(0.15), { maxZoom: 8 });
      else map.setView([38.5, -92], 4);
    })();
    return () => { cancelled = true; map?.remove(); };
  }, [points]);

  return <div ref={el} className="lead-map" role="region" aria-label="Map of leads" />;
}
