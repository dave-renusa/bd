import ExcelJS from 'exceljs';
import Papa from 'papaparse';

export type Row = Record<string, unknown>;

/** Lowercase, alphanumerics only: "MW Energy" -> "mwenergy". */
export const normKey = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');

function cellValue(v: ExcelJS.CellValue): unknown {
  if (v == null) return null;
  if (v instanceof Date) return v;
  if (typeof v === 'object') {
    if ('result' in v) return (v as ExcelJS.CellFormulaValue).result ?? null;
    if ('text' in v) return (v as ExcelJS.CellHyperlinkValue).text;
    if ('richText' in v) return (v as ExcelJS.CellRichTextValue).richText.map((t) => t.text).join('');
    return null;
  }
  return v;
}

/**
 * Reads the first worksheet of an .xlsx file into objects keyed by header.
 * The header row is the first row (within the first 20) that contains one of
 * `headerHints`, so title rows above the table are skipped.
 */
export async function readXlsx(buf: ArrayBuffer | Buffer, headerHints: string[]): Promise<Row[]> {
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(buf as ArrayBuffer);
  const ws = wb.worksheets[0];
  if (!ws) return [];
  const hints = headerHints.map(normKey);

  let headerRow = 1;
  for (let r = 1; r <= Math.min(20, ws.rowCount); r++) {
    const vals = (ws.getRow(r).values as ExcelJS.CellValue[]).map((v) => normKey(String(cellValue(v) ?? '')));
    if (vals.some((v) => hints.includes(v))) { headerRow = r; break; }
  }
  const headers = (ws.getRow(headerRow).values as ExcelJS.CellValue[]).map((v) => String(cellValue(v) ?? '').trim());

  const rows: Row[] = [];
  ws.eachRow((row, n) => {
    if (n <= headerRow) return;
    const vals = row.values as ExcelJS.CellValue[];
    const obj: Row = {};
    let any = false;
    headers.forEach((h, i) => {
      if (!h) return;
      const v = cellValue(vals[i]);
      if (v !== null && v !== '') any = true;
      obj[h] = v;
    });
    if (any) rows.push(obj);
  });
  return rows;
}

export function readCsv(text: string): Row[] {
  const out = Papa.parse<Row>(text, { header: true, skipEmptyLines: true, transformHeader: (h) => h.trim() });
  return out.data;
}

/** Reads .xlsx or .csv by sniffing the zip signature. */
export async function readSheet(buf: ArrayBuffer | Buffer, headerHints: string[]): Promise<Row[]> {
  const bytes = new Uint8Array(buf as ArrayBuffer);
  const isZip = bytes[0] === 0x50 && bytes[1] === 0x4b;
  if (isZip) return readXlsx(buf, headerHints);
  return readCsv(new TextDecoder().decode(bytes));
}

/**
 * Returns a getter that finds a column by any of several header aliases:
 * exact normalized match first, then "header contains alias".
 */
export function columnPicker(sampleRow: Row | undefined) {
  const keys = Object.keys(sampleRow ?? {});
  const norm = keys.map((k) => [k, normKey(k)] as const);
  const cache = new Map<string, string | null>();
  const find = (aliases: string[]) => {
    const id = aliases.join('|');
    if (cache.has(id)) return cache.get(id)!;
    const as = aliases.map(normKey);
    const hit = norm.find(([, n]) => as.includes(n)) ?? norm.find(([, n]) => as.some((a) => a.length > 5 && n.includes(a)));
    cache.set(id, hit?.[0] ?? null);
    return hit?.[0] ?? null;
  };
  return (row: Row, aliases: string[]): unknown => {
    const k = find(aliases);
    return k ? row[k] : null;
  };
}

export function toNumber(v: unknown): number | null {
  if (v == null || v === '') return null;
  if (typeof v === 'number') return Number.isFinite(v) ? v : null;
  const n = Number(String(v).replace(/[^0-9.\-]/g, ''));
  return Number.isFinite(n) && String(v).match(/\d/) ? n : null;
}

/** ISO date (YYYY-MM-DD) from a Date, Excel serial, or date-like string. */
export function toIsoDate(v: unknown): string | null {
  if (v == null || v === '') return null;
  let d: Date | null = null;
  if (v instanceof Date) d = v;
  else if (typeof v === 'number' && v > 20000 && v < 80000) d = new Date(Date.UTC(1899, 11, 30) + v * 86400000);
  else if (typeof v === 'number' && v >= 1900 && v <= 2100) d = new Date(Date.UTC(v, 0, 1));
  else {
    const s = String(v).trim();
    if (/^\d{4}$/.test(s)) d = new Date(Date.UTC(Number(s), 0, 1));
    else {
      const t = Date.parse(s);
      if (!Number.isNaN(t)) d = new Date(t);
    }
  }
  if (!d || Number.isNaN(d.getTime())) return null;
  return d.toISOString().slice(0, 10);
}

export function toText(v: unknown): string | null {
  if (v == null) return null;
  const s = String(v).trim();
  return s ? s : null;
}

/** JSON-safe copy of a row for the `raw` column. */
export function rawRow(row: Row): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(row)) out[k] = v instanceof Date ? v.toISOString() : v;
  return out;
}
