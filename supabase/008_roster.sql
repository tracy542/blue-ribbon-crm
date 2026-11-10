-- ============================================================
-- 008 — Agent roster lives in the CRM (Admin > Agent roster)
-- Replaces the roster page + nightly sync. Every save is queued for the
-- CDA dropdown list (Make store 154925). Sending stays OFF until Tracy
-- switches it on (app_settings roster_sync_enabled = true).
-- ============================================================

-- New role: staff (Donna). Can edit the roster. Sees no leads.
alter table agents drop constraint if exists agents_role_check;
alter table agents add constraint agents_role_check check (role in ('agent','broker','admin','staff'));

create or replace function is_roster_editor() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('broker','admin','staff') from agents
                    where auth_user_id = auth.uid() and active limit 1), false)
$$;

create table if not exists roster (
  agent_id        text primary key check (agent_id ~ '^[0-9]{7}$'),
  first           text not null default '',
  last            text not null default '',
  email           text not null default '',
  phone           text not null default '',
  office          text not null default '' check (office in ('','MBG','FR','Bow','REF')),
  status          text not null default 'active' check (status in ('active','referral','inactive')),
  mls_id          text not null default '',
  licenses        jsonb not null default '[]',       -- [{state, number, exp}]
  mailing         text not null default '',
  hire_date       date,
  inactive_on     date,
  inactive_by     text not null default '',
  -- Plan (what BrokerSumo / the agent's plan says)
  plan_name       text not null default '',
  split           text not null default '',
  split_pct       numeric,
  net_pct         numeric,
  pays_arf        text not null default '' check (pays_arf in ('','yes','no')),
  split_note      text not null default '',
  split_review    text not null default '',
  split_verified  jsonb,                              -- {at, by, note}
  -- What the CDA form uses to pay the agent (copied exactly from store 154925)
  cda_split_pct   text,                               -- standard_split_pct
  cda_arf_pct     text,                               -- arf_pct ("0" = no ARF/admin fee; blank = standard)
  in_cda_list     boolean not null default false,     -- has a record in store 154925
  cda_record      jsonb,                              -- last known store record, kept whole
  -- Monthly fee (Stripe)
  fee_status      text not null default '',
  fee_since       text not null default '',
  fee_checked_at  text not null default '',
  fee_override    text not null default '',
  -- BrokerSumo
  brokersumo_id     text not null default '',
  not_in_brokersumo boolean not null default false,
  notes           text not null default '',
  source          text not null default '',
  -- CDA list sync
  sync_state      text not null default 'ok' check (sync_state in ('ok','waiting','sending','error','off')),
  sync_error      text not null default '',
  synced_at       timestamptz,
  updated_at      timestamptz not null default now(),
  updated_by      text not null default ''
);

-- One line per change (who changed what)
create table if not exists roster_history (
  id bigint generated always as identity primary key,
  agent_id text not null,
  at timestamptz not null default now(),
  by text not null default '',
  changes jsonb not null
);

alter table roster enable row level security;
alter table roster_history enable row level security;
drop policy if exists roster_read on roster;
drop policy if exists roster_add on roster;
drop policy if exists roster_edit on roster;
drop policy if exists roster_hist_read on roster_history;
create policy roster_read on roster for select to authenticated using (is_roster_editor());
create policy roster_add  on roster for insert to authenticated with check (is_roster_editor());
create policy roster_edit on roster for update to authenticated using (is_roster_editor()) with check (is_roster_editor());
create policy roster_hist_read on roster_history for select to authenticated using (is_roster_editor());
-- No delete: mark inactive instead.

-- Staff can open the office list and their own agent row; that's it.
-- (contacts/tasks rules already show staff nothing: no office pond, not a boss.)

insert into app_settings (key, value) values ('roster_sync_enabled', 'false') on conflict (key) do nothing;

-- ------------------------------------------------------------
-- What the CDA dropdown record should say for one roster row.
-- Only these fields are written; Make keeps every other field as it is.
-- ------------------------------------------------------------
create or replace function roster_cda_payload(r roster) returns jsonb
language sql immutable as $$
  select jsonb_build_object(
    'agent_id',           r.agent_id,
    'name',               trim(r.first || ' ' || r.last),
    'email',              r.email,
    'cell_phone',         r.phone,
    'office',             r.office,
    'active',             case when r.status = 'inactive' then 'false' else 'true' end,
    'mls_agent_id',       r.mls_id,
    'license_numbers',    coalesce((select string_agg(l->>'number', ', ' order by o) from jsonb_array_elements(r.licenses) with ordinality t(l, o)), ''),
    'license_state',      coalesce((select string_agg(l->>'state',  ', ' order by o) from jsonb_array_elements(r.licenses) with ordinality t(l, o)), ''),
    'mailing_address',    r.mailing,
    'standard_split_pct', coalesce(r.cda_split_pct, ''),
    'arf_pct',            coalesce(r.cda_arf_pct, '')
  )
$$;

-- Fields that differ between what the CRM would send and what the CDA list has now.
-- Blank and empty count as the same. Used for the dry run and the page's "CDA list" check.
create or replace function roster_cda_diff(r roster) returns jsonb
language sql stable as $$
  select coalesce(jsonb_object_agg(p.key, jsonb_build_object('crm', p.value, 'cda', r.cda_record -> p.key)), '{}'::jsonb)
  from jsonb_each_text(roster_cda_payload(r)) p
  where r.cda_record is not null
    and coalesce(p.value, '') is distinct from coalesce(r.cda_record ->> p.key, '')
$$;

-- ------------------------------------------------------------
-- On every save: stamp, log what changed, keep the CRM login row in step,
-- and queue the CDA list update when a CDA field changed.
-- ------------------------------------------------------------
create or replace function roster_before_save() returns trigger
language plpgsql security definer set search_path = public as $$
declare chg jsonb := '{}'; k text; who text;
begin
  -- Sync results and the one-time import write quietly (no stamping, no re-queue)
  if current_setting('roster.quiet', true) = 'on' then return new; end if;
  who := coalesce((select full_name from agents where auth_user_id = auth.uid() limit 1), case when tg_op = 'INSERT' then nullif(new.updated_by, '') end, 'system');
  new.updated_by := who;
  new.updated_at := now();
  if new.status = 'inactive' and new.inactive_on is null then new.inactive_on := current_date; new.inactive_by := who; end if;
  if new.status <> 'inactive' then new.inactive_on := null; new.inactive_by := ''; end if;

  if tg_op = 'UPDATE' then
    for k in select key from jsonb_each(to_jsonb(new)) loop
      if k in ('updated_at','updated_by','sync_state','sync_error','synced_at','cda_record') then continue; end if;
      if to_jsonb(new) -> k is distinct from to_jsonb(old) -> k then
        chg := chg || jsonb_build_object(k, jsonb_build_object('from', to_jsonb(old) -> k, 'to', to_jsonb(new) -> k));
      end if;
    end loop;
    if chg <> '{}' then insert into roster_history (agent_id, by, changes) values (new.agent_id, who, chg); end if;
    -- Queue for the CDA list only when something the list holds changed
    if roster_cda_payload(new) is distinct from roster_cda_payload(old) and new.sync_state not in ('sending') then
      new.sync_state := 'waiting'; new.sync_error := '';
    end if;
  else
    insert into roster_history (agent_id, by, changes) values (new.agent_id, who, jsonb_build_object('added', true));
    -- New active/referral agents go on the CDA list; new inactive ones don't
    if new.status <> 'inactive' and new.cda_record is null then new.sync_state := 'waiting'; end if;
  end if;
  return new;
end $$;
drop trigger if exists roster_before_save on roster;
create trigger roster_before_save before insert or update on roster
  for each row execute function roster_before_save();

-- Keep the CRM sign-in list (agents) in step with the roster: active agents can sign in.
create or replace function roster_after_save() returns trigger
language plpgsql security definer set search_path = public as $$
declare co uuid; off uuid;
begin
  if new.email = '' then return new; end if;
  select id into co from companies where name = 'Blue Ribbon Realty';
  select id into off from offices where company_id = co and name =
    case new.office when 'MBG' then 'Martinsburg' when 'FR' then 'Front Royal' when 'Bow' then 'Bowie' when 'REF' then 'Referral' end;
  update agents set full_name = trim(new.first || ' ' || new.last),
                    email = new.email,
                    office_id = coalesce(off, office_id),
                    active = case when role in ('broker','admin','staff') then active else new.status = 'active' end
   where agent_number = new.agent_id;
  if not found and new.status = 'active'
     and not exists (select 1 from agents where lower(email) = lower(new.email)) then
    insert into agents (company_id, office_id, agent_number, full_name, email, role)
    values (co, off, new.agent_id, trim(new.first || ' ' || new.last), new.email, 'agent');
  end if;
  return new;
end $$;
drop trigger if exists roster_after_save on roster;
create trigger roster_after_save after insert or update on roster
  for each row execute function roster_after_save();

-- ------------------------------------------------------------
-- The sender (Make bot ROSTER-002) calls these with the service key:
--   roster_sync_next()        -> rows waiting, with their payloads (only when switched on)
--   roster_sync_done(id, ok, error, record) -> marks the result
-- ------------------------------------------------------------
create or replace function roster_sync_next(max_rows int default 25) returns jsonb
language plpgsql security definer set search_path = public as $$
declare out jsonb;
begin
  if coalesce((select value from app_settings where key = 'roster_sync_enabled'), 'false') <> 'true' then
    return jsonb_build_object('enabled', false, 'rows', '[]'::jsonb);
  end if;
  with picked as (
    select agent_id from roster
     where sync_state = 'waiting' or (sync_state = 'sending' and updated_at < now() - interval '10 minutes')
     order by updated_at limit max_rows for update skip locked
  ), marked as (
    update roster r set sync_state = 'sending' from picked p where r.agent_id = p.agent_id returning r.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('key', m.agent_id, 'is_new', m.cda_record is null,
                                               'data', roster_cda_payload(m))), '[]'::jsonb)
    into out from marked m;
  return jsonb_build_object('enabled', true, 'rows', out);
end $$;

create or replace function roster_sync_done(p_agent_id text, p_ok boolean, p_error text default '', p_record jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform set_config('roster.quiet', 'on', true);
  update roster set sync_state = case when p_ok then 'ok' else 'error' end,
                    sync_error = case when p_ok then '' else coalesce(p_error, 'unknown error') end,
                    synced_at  = case when p_ok then now() else synced_at end,
                    cda_record = case when p_ok and p_record is not null then p_record else cda_record end,
                    in_cda_list = in_cda_list or p_ok
   where agent_id = p_agent_id;
  perform set_config('roster.quiet', 'off', true);
end $$;

revoke all on function roster_sync_next(int) from public, anon, authenticated;
revoke all on function roster_sync_done(text, boolean, text, jsonb) from public, anon, authenticated;

-- ------------------------------------------------------------
-- Flags for the roster page (money items are flagged, never auto-fixed)
-- ------------------------------------------------------------
create or replace view roster_flags with (security_invoker = true) as
select r.agent_id,
  array_remove(array[
    case when r.status <> 'inactive' and r.cda_split_pct is distinct from null and r.split_pct is not null
          and nullif(r.cda_split_pct, '')::numeric is distinct from r.split_pct
         then 'CDA split ' || coalesce(nullif(r.cda_split_pct, ''), 'blank') || '% vs plan ' || r.split_pct || '%' end,
    case when r.status <> 'inactive' and r.pays_arf = 'no' and coalesce(r.cda_arf_pct, '') = ''
         then 'Plan says no ARF, but the CDA charges the standard ARF' end,
    case when r.status <> 'inactive' and r.pays_arf = 'yes' and coalesce(r.cda_arf_pct, '') <> ''
         then 'Plan says pays ARF, but the CDA ARF is ' || r.cda_arf_pct end,
    case when r.status <> 'inactive' and not r.in_cda_list then 'Not on the CDA list yet' end,
    case when r.status <> 'inactive' and r.email = '' then 'No email' end,
    case when r.status = 'active' and exists (select 1 from jsonb_array_elements(r.licenses) l
                                               where (l->>'exp') ~ '^\d{4}-\d{2}-\d{2}$' and (l->>'exp')::date < current_date + 60)
         then 'License expires within 60 days' end,
    case when r.sync_state = 'error' then 'CDA list update failed: ' || r.sync_error end,
    nullif(r.split_review, '')
  ], null) as flags
from roster r;
grant select on roster_flags to authenticated;

-- Donna: office staff. Edits the roster; sees no leads.
-- No office on purpose: an office would show her that office's lead pond.
insert into agents (company_id, office_id, full_name, email, role)
select c.id, null, 'Donna', 'donna@weichertblueribbon.com', 'staff'
from companies c where c.name = 'Blue Ribbon Realty'
on conflict (email) do nothing;
