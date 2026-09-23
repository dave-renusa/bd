-- BD Radar: looser county matching, from the first PJM run.
-- - "DeWitt" and "De Witt" now match: spaces are ignored.
-- - "King and Queen" no longer splits on "and" (only ; / , & separate counties).
-- - "City of Chesapeake" matches "Chesapeake city".
-- - PJM queue IDs drop transition notes ("AH1-716 - moved to TC2" -> "AH1-716").

create or replace function bd.norm_county(p text) returns text
language sql immutable set search_path = bd, pg_temp as $$
  select nullif(regexp_replace(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(lower(coalesce(p, '')), '[^a-z0-9 ]', '', 'g'),
          '^\s*city of\s+(.+)$', '\1 city'),
        '\s+(county|parish|borough|census area|city and borough|municipality)\s*$', ''),
      '^\s*saint\s+', 'st '),
    '\s+', '', 'g'), '')
$$;

create or replace function bd.match_county(p_state text, p_county text) returns text
language sql stable set search_path = bd, pg_temp as $$
  select j.fips
  from bd.jurisdictions j
  where j.kind = 'county'
    and j.state = upper(trim(p_state))
    and j.norm_name = bd.norm_county(split_part(regexp_replace(coalesce(p_county, ''), '[;/,&]', ';', 'g'), ';', 1))
  order by j.fips
  limit 1
$$;

-- Recompute the stored norm_name with the new rules.
update bd.jurisdictions set county = county where kind = 'county';

-- Strip transition notes from PJM queue IDs already loaded.
update bd.projects p set queue_id = split_part(p.queue_id, ' - ', 1)
 where p.iso = 'PJM' and p.queue_id like '% - %'
   and not exists (select 1 from bd.projects o
                   where o.iso = 'PJM' and o.queue_id = split_part(p.queue_id, ' - ', 1) and o.id <> p.id);

-- Retry county matches for projects that did not match the first time.
update bd.projects p set fips = bd.match_county(p.state, p.county)
 where p.fips is null and p.county is not null and bd.match_county(p.state, p.county) is not null;

revoke execute on all functions in schema bd from public;
grant execute on all functions in schema bd to service_role;
