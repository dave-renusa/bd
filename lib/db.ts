import { createClient, type SupabaseClient } from '@supabase/supabase-js';

// Service-role client scoped to the `bd` schema. Server only: this key
// bypasses RLS, so never import this file into a client component.
let client: SupabaseClient<any, 'bd'> | null = null;

export function db(): SupabaseClient<any, 'bd'> {
  if (typeof window !== 'undefined') throw new Error('db() is server only');
  if (!client) {
    const url = process.env.SUPABASE_URL;
    const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
    if (!url || !key) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set');
    client = createClient<any, 'bd'>(url, key, {
      db: { schema: 'bd' },
      auth: { persistSession: false, autoRefreshToken: false },
    });
  }
  return client;
}

/** Calls a bd.* function and throws on error. */
export async function rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): Promise<T> {
  const { data, error } = await db().rpc(fn, args);
  if (error) throw new Error(`${fn}: ${error.message}`);
  return data as T;
}

export async function enabledFootprint(): Promise<Set<string>> {
  const { data, error } = await db().from('footprint').select('state').eq('enabled', true);
  if (error) throw new Error(`footprint: ${error.message}`);
  return new Set((data ?? []).map((r) => r.state as string));
}

export async function settingNumber(key: string, fallback: number): Promise<number> {
  const { data } = await db().from('settings').select('value').eq('key', key).maybeSingle();
  const n = Number(data?.value);
  return Number.isFinite(n) ? n : fallback;
}
