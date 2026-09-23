-- BD Radar: people import path (RenUSA contact CSV).
-- scripts/import-people.ts parses the CSV and calls bd.import_people over RPC.
-- Re-importing the same person updates them instead of duplicating.

create unique index people_name_company_key
  on bd.people (lower(full_name), lower(coalesce(current_company, '')));

-- p_rows: array of {full_name, current_company, current_title, email, linkedin_url,
--   relationship_owner, relationship_strength, notes}
-- Links each person to a developer when current_company matches a developer
-- name or parent name.
create or replace function bd.import_people(p_rows jsonb) returns jsonb
language plpgsql set search_path = bd, pg_temp as $$
declare n_in int; n_linked int;
begin
  insert into bd.people (full_name, current_company, current_title, email, linkedin_url,
                         relationship_owner, relationship_strength, notes, developer_id,
                         source, created_by)
  select trim(x.full_name), nullif(trim(x.current_company), ''), nullif(trim(x.current_title), ''),
         nullif(trim(x.email), ''), nullif(trim(x.linkedin_url), ''), nullif(trim(x.relationship_owner), ''),
         case when x.relationship_strength between 1 and 3 then x.relationship_strength end,
         nullif(trim(x.notes), ''),
         (select d.id from bd.developers d
           where lower(d.name) = lower(trim(x.current_company))
              or lower(d.parent_name) = lower(trim(x.current_company))
           order by (lower(d.name) = lower(trim(x.current_company))) desc limit 1),
         'import', 'import:csv'
  from (
    -- one row per person; the last occurrence in the file wins
    select distinct on (lower(trim(r.full_name)), lower(coalesce(nullif(trim(r.current_company), ''), '')))
           r.*
    from rows from (jsonb_to_recordset(p_rows) as (
      full_name text, current_company text, current_title text, email text, linkedin_url text,
      relationship_owner text, relationship_strength smallint, notes text))
      with ordinality as r(full_name, current_company, current_title, email, linkedin_url,
                           relationship_owner, relationship_strength, notes, n)
    where nullif(trim(r.full_name), '') is not null
    order by lower(trim(r.full_name)), lower(coalesce(nullif(trim(r.current_company), ''), '')), r.n desc
  ) x
  on conflict (lower(full_name), lower(coalesce(current_company, ''))) do update set
    current_title = coalesce(excluded.current_title, bd.people.current_title),
    email = coalesce(excluded.email, bd.people.email),
    linkedin_url = coalesce(excluded.linkedin_url, bd.people.linkedin_url),
    relationship_owner = coalesce(excluded.relationship_owner, bd.people.relationship_owner),
    relationship_strength = coalesce(excluded.relationship_strength, bd.people.relationship_strength),
    notes = coalesce(excluded.notes, bd.people.notes),
    developer_id = coalesce(bd.people.developer_id, excluded.developer_id);
  get diagnostics n_in = row_count;
  select count(*) into n_linked from bd.people where developer_id is not null;
  return jsonb_build_object('upserted', n_in, 'people_linked_to_developers', n_linked);
end $$;

revoke execute on function bd.import_people(jsonb) from public;
grant execute on function bd.import_people(jsonb) to service_role;
