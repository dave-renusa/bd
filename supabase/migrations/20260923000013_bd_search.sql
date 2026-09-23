-- BD Radar: lead search.
-- Filters leads by state, technology, kind, stage, owner and minimum score,
-- and by keywords. Every keyword must appear somewhere in the lead's name,
-- developer, place, county, restriction, queue ID or why-now text, or in the
-- headline or text of any of its signals (Sabin descriptions, Greenlight
-- outcomes). Matching is case-insensitive substring matching.

create or replace function bd.search_leads(
  p_q text default null,
  p_state text default null,
  p_tech text default null,
  p_kind text default null,
  p_stage text default null,
  p_owner text default null,
  p_min int default 0,
  p_limit int default 500
) returns setof bd.lead_view
language plpgsql stable set search_path = bd, pg_temp as $$
declare
  v_words text[];
begin
  -- Keywords, with LIKE wildcards escaped so "100%" or "a_b" match literally.
  select coalesce(array_agg('%' || replace(replace(replace(w, '\', '\\'), '%', '\%'), '_', '\_') || '%'), '{}')
    into v_words
  from unnest(regexp_split_to_array(trim(coalesce(p_q, '')), '\s+')) w
  where w <> '';

  return query
  select v.*
  from bd.lead_view v
  where (p_state is null or v.subject_state = upper(p_state))
    and (p_tech is null or v.subject_technology::text = p_tech)
    and (p_kind is null or v.kind::text = p_kind)
    and (p_stage is null or v.stage::text = p_stage)
    and (p_owner is null or (p_owner = '_none' and v.owner is null) or v.owner = p_owner)
    and v.score >= coalesce(p_min, 0)
    and (cardinality(v_words) = 0 or (
      select bool_and(d.doc ilike w)
      from (
        select concat_ws(' ', v.display_name, v.developer_name, v.developer_parent, v.place_name,
                         v.county_name, v.subject_state, v.restriction_type, v.queue_id, v.why_now,
                         (select string_agg(concat_ws(' ', s.headline, s.detail), ' ')
                            from (select s1.headline, s1.detail from bd.signals s1
                                   where s1.project_id = v.project_id and not s1.is_noise
                                  union all
                                  select s2.headline, s2.detail from bd.signals s2
                                   where s2.lead_id = v.id and s2.project_id is distinct from v.project_id
                                     and not s2.is_noise) s)) as doc
      ) d, unnest(v_words) w
    ))
  order by v.score desc, v.last_signal_at desc nulls last
  limit least(coalesce(p_limit, 500), 1000);
end $$;

revoke all on function bd.search_leads(text, text, text, text, text, text, int, int) from public;
grant execute on function bd.search_leads(text, text, text, text, text, text, int, int) to service_role;
