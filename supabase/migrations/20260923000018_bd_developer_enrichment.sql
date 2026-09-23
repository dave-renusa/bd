-- BD Radar: developer enrichment.
-- PJM and Sabin files carry no developer column, but Sabin descriptions often
-- name one. A Claude task reads those descriptions and loads what it finds
-- through bd.set_project_developers, which only fills a project that has no
-- developer yet (it never overwrites) and records that the text was read,
-- so a project is not re-read every week.

alter table bd.projects add column if not exists developer_checked_at timestamptz;

-- Items: [{"project_id": uuid, "developer": text or null, "parent": text or null}].
-- A null developer means the text was read and names none.
create or replace function bd.set_project_developers(p_items jsonb) returns jsonb
language plpgsql set search_path = bd, pg_temp as $$
declare r record; v_dev uuid; n_set int := 0; n_checked int := 0;
begin
  for r in
    select x.project_id, nullif(trim(x.developer), '') as developer, nullif(trim(x.parent), '') as parent
    from jsonb_to_recordset(p_items) as x(project_id uuid, developer text, parent text)
  loop
    update bd.projects set developer_checked_at = now() where id = r.project_id;
    n_checked := n_checked + 1;
    continue when r.developer is null;
    v_dev := bd.upsert_developer(r.developer, (select technology from bd.projects where id = r.project_id));
    if r.parent is not null then
      update bd.developers set parent_name = r.parent where id = v_dev and parent_name is null;
    end if;
    update bd.projects set developer_id = v_dev, developer_raw = coalesce(developer_raw, r.developer)
    where id = r.project_id and developer_id is null;
    if found then
      n_set := n_set + 1;
      -- keep the project's lead pointing at the same developer
      update bd.leads set developer_id = v_dev where project_id = r.project_id and developer_id is null;
    end if;
  end loop;
  return jsonb_build_object('checked', n_checked, 'developers_set', n_set);
end $$;

-- Projects whose descriptions have not been read yet: current (not merged)
-- projects with no developer and a Sabin write-up.
create or replace view bd.developer_enrichment_queue with (security_invoker = true) as
select p.id as project_id, p.name, p.state, p.county, p.technology,
       left(coalesce(p.raw->>'Content', ''), 1500) as description
from bd.projects p
where p.developer_id is null and p.merged_into is null and not p.is_noise
  and p.developer_checked_at is null
  and coalesce(p.raw->>'Content', '') <> '';
