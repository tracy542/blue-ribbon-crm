-- ============================================================
-- 013 — Office leads go straight to an agent, taking turns (Tracy, 11/10/2026: Option 1)
--   Maryland ZIPs       → Priscilla Lane and Regina Parker, in turn
--   DC ZIPs             → Tracy Adams (neither Bowie agent shows a DC license on the roster)
--   Everything else     → Jonathan Fleming, Gavin Washington, Tracy Adams, in turn
--   Not contacted in 48 hours → back to that area's office pond (existing hourly job)
-- ============================================================
create table if not exists lead_rotations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  name text not null unique,
  agent_ids uuid[] not null,          -- who takes turns, in order
  next_index int not null default 0,  -- whose turn is next (0 = first)
  pond_id uuid references ponds(id) on delete set null,  -- where unworked leads go back to
  created_at timestamptz not null default now()
);
alter table lead_rotations enable row level security;
drop policy if exists rotations_boss on lead_rotations;
create policy rotations_boss on lead_rotations for all to authenticated using (is_boss()) with check (is_boss());

alter table lead_flow_rules add column if not exists match_zip_regex text;            -- e.g. '^(200|20[2-9]|21[0-9])' for MD + DC
alter table lead_flow_rules add column if not exists to_rotation_id uuid references lead_rotations(id) on delete set null;
alter table lead_flow_rules add column if not exists return_pond_id uuid references ponds(id) on delete set null;
alter table lead_flow_rules drop constraint if exists lead_flow_rules_check;
alter table lead_flow_rules add constraint lead_flow_rules_check
  check (to_agent_id is not null or to_pond_id is not null or to_rotation_id is not null);

-- Pick whose turn it is and move the pointer (locked so two leads at once don't get the same agent)
create or replace function rotation_next(p_rotation uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare rot lead_rotations; pick uuid; i int; tries int := 0;
begin
  select * into rot from lead_rotations where id = p_rotation for update;
  if rot.id is null or coalesce(array_length(rot.agent_ids, 1), 0) = 0 then return null; end if;
  i := rot.next_index;
  loop                                                   -- skip anyone who's been made inactive
    pick := rot.agent_ids[(i % array_length(rot.agent_ids, 1)) + 1];
    i := i + 1; tries := tries + 1;
    exit when exists (select 1 from agents where id = pick and active) or tries >= array_length(rot.agent_ids, 1);
  end loop;
  update lead_rotations set next_index = i % array_length(rot.agent_ids, 1) where id = p_rotation;
  return pick;
end $$;

create or replace function route_new_lead(p_contact uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c contacts; r lead_flow_rules; who uuid; back_pond uuid;
begin
  select * into c from contacts where id = p_contact;
  select * into r from lead_flow_rules
   where active and company_id = c.company_id
     and (match_source is null or lower(match_source) = lower(coalesce(c.source,'')))
     and (match_zip_prefix is null or coalesce(c.zip,'') like match_zip_prefix || '%')
     and (match_zip_regex is null or coalesce(c.zip,'') ~ match_zip_regex)
   order by priority limit 1;
  if r.id is null then return; end if;                   -- no rule: stays where intake put it
  if r.to_rotation_id is not null then
    who := rotation_next(r.to_rotation_id);
    select coalesce(r.return_pond_id, (select pond_id from lead_rotations where id = r.to_rotation_id)) into back_pond;
  else
    who := r.to_agent_id; back_pond := r.return_pond_id;
  end if;
  if who is not null then
    -- straight to the agent; claimed_from_pond_id makes the 48-hour "back to the pond" rule apply
    update contacts set owner_agent_id = who, pond_id = null, claimed_from_pond_id = back_pond,
                        assigned_at = now(), updated_at = now() where id = p_contact;
  elsif r.to_pond_id is not null then
    update contacts set pond_id = r.to_pond_id, owner_agent_id = null, updated_at = now() where id = p_contact;
  end if;
  if r.start_plan_id is not null then perform enroll_contact(p_contact, r.start_plan_id); end if;
end $$;
revoke all on function route_new_lead(uuid) from public, anon, authenticated;
revoke all on function rotation_next(uuid) from public, anon, authenticated;

-- The two starting rotations
insert into lead_rotations (company_id, name, agent_ids, pond_id)
select c.id, 'WV / VA / PA office leads',
       array[(select id from agents where agent_number = '5219307'),   -- Jonathan Fleming
             (select id from agents where agent_number = '5042252'),   -- Gavin Washington
             (select id from agents where agent_number = '1100511')],  -- Tracy Adams
       (select id from ponds where name = 'Martinsburg office leads')
from companies c where c.name = 'Blue Ribbon Realty'
on conflict (name) do nothing;

insert into lead_rotations (company_id, name, agent_ids, pond_id)
select c.id, 'MD office leads',
       array[(select id from agents where agent_number = '6077543'),   -- Priscilla Lane
             (select id from agents where agent_number = '2373093')],  -- Regina Parker
       (select id from ponds where name = 'Bowie office leads')
from companies c where c.name = 'Blue Ribbon Realty'
on conflict (name) do nothing;

-- New rules replace the old pond-only rules (kept, switched off)
update lead_flow_rules set active = false where priority in (50, 60, 100) and to_rotation_id is null;

insert into lead_flow_rules (company_id, priority, label, match_source, match_zip_regex, to_agent_id, return_pond_id, start_plan_id)
select c.id, 5, 'Blue Ribbon Homes website, DC ZIP → Tracy Adams, start "New buyer lead, 30 days"',
       'Blue Ribbon Homes', '^(200|20[2-5])',
       (select id from agents where agent_number = '1100511'),
       (select id from ponds where name = 'Bowie office leads'),
       (select id from action_plans where name = 'New buyer lead, 30 days')
from companies c where c.name = 'Blue Ribbon Realty'
  and not exists (select 1 from lead_flow_rules where priority = 5);

insert into lead_flow_rules (company_id, priority, label, match_source, match_zip_regex, to_rotation_id, start_plan_id)
select c.id, 10, 'Blue Ribbon Homes website, Maryland ZIP → Priscilla Lane, Regina Parker taking turns, start "New buyer lead, 30 days"',
       'Blue Ribbon Homes', '^(20[6-9]|21[0-9])',
       (select id from lead_rotations where name = 'MD office leads'),
       (select id from action_plans where name = 'New buyer lead, 30 days')
from companies c where c.name = 'Blue Ribbon Realty'
  and not exists (select 1 from lead_flow_rules where priority = 10);

insert into lead_flow_rules (company_id, priority, label, match_source, to_rotation_id, start_plan_id)
select c.id, 20, 'Blue Ribbon Homes website, everywhere else → Jonathan, Gavin, Tracy taking turns, start "New buyer lead, 30 days"',
       'Blue Ribbon Homes',
       (select id from lead_rotations where name = 'WV / VA / PA office leads'),
       (select id from action_plans where name = 'New buyer lead, 30 days')
from companies c where c.name = 'Blue Ribbon Realty'
  and not exists (select 1 from lead_flow_rules where priority = 20);
