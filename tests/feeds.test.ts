import ExcelJS from 'exceljs';
import { describe, expect, it } from 'vitest';
import { normalizePjm, parsePjmQueue, pjmTechnology } from '../lib/feeds/pjm';
import { classifySabinSheet, findSabinLinks, normalizeContested, normalizeRestrictions, sabinStage } from '../lib/feeds/sabin';
import { readCsv, toIsoDate } from '../lib/sheets';
import { toStateCode } from '../lib/states';

async function xlsx(rows: unknown[][]): Promise<Buffer> {
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Queue');
  rows.forEach((r) => ws.addRow(r));
  return Buffer.from(await wb.xlsx.writeBuffer());
}

const footprint = new Set(['VA', 'PA', 'OH', 'TX']);

describe('PJM queue', () => {
  it('maps fuel to technology', () => {
    expect(pjmTechnology('Solar; Storage')).toBe('solar_bess');
    expect(pjmTechnology('Solar')).toBe('solar');
    expect(pjmTechnology('Offshore Wind')).toBe('wind');
    expect(pjmTechnology('Storage')).toBe('bess');
    expect(pjmTechnology('Natural Gas')).toBe('other');
  });

  it('parses the export, skips a title row, and filters scope', async () => {
    const buf = await xlsx([
      ['PJM New Services Queue export'],
      ['Project ID', 'Name', 'Commercial Name', 'State', 'County', 'Status', 'Submitted Date', 'Fuel', 'MW Capacity', 'MW Energy', 'MFO'],
      ['AG1-001', 'Doe 138kV', 'Sunny Acres', 'VA', 'Loudoun', 'Active', new Date(Date.UTC(2026, 2, 1)), 'Solar', 80, 120, 120],
      ['AG1-002', 'Small 34.5kV', null, 'VA', 'Clarke', 'Active', new Date(Date.UTC(2026, 2, 1)), 'Solar', 10, 20, 20],
      ['AG1-003', 'Gas Plant', null, 'PA', 'York', 'Active', new Date(Date.UTC(2026, 2, 1)), 'Natural Gas', 900, 900, 900],
      ['AG1-004', 'Far Away', null, 'IL', 'Cook', 'Active', new Date(Date.UTC(2026, 2, 1)), 'Wind', 200, 200, 200],
      ['AG1-005', 'Ohio BESS', null, 'Ohio', 'Franklin', 'Withdrawn', '2025-06-15', 'Storage', 150, 150, null],
      ['AG1-006', 'Built Wind', null, 'PA', 'Somerset', 'In Service', '2019-01-01', 'Wind', 90, 90, 90],
    ]);
    const rows = await parsePjmQueue(buf);
    expect(rows).toHaveLength(6);
    const out = normalizePjm(rows, { mwFloor: 50, footprint });
    expect(out.map((r) => r.queue_id)).toEqual(['AG1-001', 'AG1-005', 'AG1-006']);
    const [sunny, bess, built] = out;
    expect(sunny).toMatchObject({ name: 'Sunny Acres', technology: 'solar', mw_ac: 120, state: 'VA', county: 'Loudoun', entered_at: '2026-03-01', is_withdrawn: false, is_built: false });
    expect(bess).toMatchObject({ technology: 'bess', mw_storage: 150, state: 'OH', is_withdrawn: true });
    expect(built.is_built).toBe(true);
  });
});

describe('Sabin', () => {
  it('normalizes restrictions with varied headers', () => {
    const rows = readCsv([
      'State,County,Locality,Type of Restriction,Description,Energy Type,Date Enacted',
      'Virginia,Frederick County,,Acreage cap,"Caps solar at 1% of land",Solar,2025-05-01',
      'Louisiana,St. Mary Parish,,Moratorium,"One-year BESS moratorium",Battery Storage,2026',
      ',,,,,,',
    ].join('\n'));
    const out = normalizeRestrictions(rows);
    expect(out).toHaveLength(2);
    expect(out[0]).toMatchObject({ state: 'VA', county: 'Frederick County', restriction_type: 'Acreage cap', technologies: ['solar'], effective: '2025-05-01', is_moratorium: false });
    expect(out[1]).toMatchObject({ state: 'LA', technologies: ['bess'], is_moratorium: true, effective: '2026-01-01' });
    expect(out[0].key).not.toBe(out[1].key);
  });

  it('normalizes contested projects and maps outcomes', () => {
    const rows = readCsv([
      'Project Name,State,County,Technology,Capacity (MW),Status,Developer',
      'Big Sky Solar,Ohio,Logan,Solar,300,Denied by OPSB,Example Energy',
      'Lake Wind,New York,Chautauqua,Wind,120,Pending,',
    ].join('\n'));
    const out = normalizeContested(rows);
    expect(out[0]).toMatchObject({ project_name: 'Big Sky Solar', state: 'OH', technology: 'solar', mw: 300, stage: 'denied', developer: 'Example Energy' });
    expect(out[1]).toMatchObject({ stage: 'contested', developer: null });
    expect(sabinStage('Withdrawn by developer')).toBe('withdrawn');
    expect(sabinStage('Approved with conditions')).toBe('approved');
  });

  it('finds file and WordPress export links on the report page', () => {
    const html = '<a href="/wp-content/uploads/2026/09/Restrictions-Sep-2026.xlsx">R</a> '
      + '<a class="btn" href="https://oppositionreport.org/wp-load.php?security_token=ab12&amp;export_id=4&amp;action=get_data"><span>Download Contested Project Data</span></a> '
      + '<a href="/about">About</a>';
    expect(findSabinLinks(html)).toEqual([
      { url: 'https://oppositionreport.org/wp-content/uploads/2026/09/Restrictions-Sep-2026.xlsx', text: 'R' },
      { url: 'https://oppositionreport.org/wp-load.php?security_token=ab12&export_id=4&action=get_data', text: 'Download Contested Project Data' },
    ]);
  });

  it('tells the two files apart by their headers', () => {
    expect(classifySabinSheet([{ State: 'VA', County: 'X', 'Type of Restriction': 'Moratorium' }])).toBe('restrictions');
    expect(classifySabinSheet([{ 'Project Name': 'A', State: 'OH', Capacity: 100 }])).toBe('contested');
    expect(classifySabinSheet([{ Foo: 1 }])).toBeNull();
  });
});

describe('helpers', () => {
  it('converts states and dates', () => {
    expect(toStateCode('west virginia')).toBe('WV');
    expect(toStateCode('dc')).toBe('DC');
    expect(toStateCode('Puerto Rico')).toBeNull();
    expect(toIsoDate(46082)).toBe('2026-03-01');
    expect(toIsoDate('not a date')).toBeNull();
  });
});
