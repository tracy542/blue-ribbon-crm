-- Light CRM — thin slice database setup
-- What this does: creates the tables, turns a lead "hot" automatically
-- when they view the same home 3 times in 7 days (or save one / ask for a showing),
-- and locks each agent to their own leads plus their office pond.

-- Companies: realty, title, school, lending
create table companies (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

-- Offices: Martinsburg, Front Royal, Bowie, Referral
create table offices (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  name text not null,
  state text,
  created_at timestamptz not null default now()
);

-- Agents: auth_user_id links to the Supabase login (magic link by email)
create table agents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  office_id uuid references offices(id) on delete set null,
  auth_user_id uuid unique,
  agent_number text unique,            -- 7-digit agent ID
  full_name text not null,
  email text not null unique,
  role text not null default 'agent' check (role in ('agent','broker','admin')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Ponds: shared lead pools per office
create table ponds (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  office_id uuid references offices(id),
  name text not null,
  created_at timestamptz not null default now()
);

-- Contacts: every lead / client
create table contacts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  owner_agent_id uuid references agents(id) on delete set null,
  pond_id uuid references ponds(id) on delete set null,
  first_name text, last_name text, email text, phone text,
  stage text not null default 'new_lead'
    check (stage in ('new_lead','active','client','under_contract','closed','sphere','dead')),
  source text,
  tags text[] not null default '{}',
  is_hot boolean not null default false,
  hot_reason text,                     -- e.g. "Looked at 118 Tavern Rd 3 times this week"
  hot_at timestamptz,
  last_contacted_at timestamptz,
  idx_lead_id text,                    -- IDX Broker's id for this lead
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (owner_agent_id is not null or pond_id is not null)  -- every lead belongs somewhere
);
create unique index contacts_email_uq on contacts (company_id, lower(email)) where email is not null;
create index on contacts (owner_agent_id, is_hot);
create index on contacts (pond_id);
create index on contacts (phone);

-- Events: each website action from IDX Broker
create table events (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references contacts(id) on delete cascade,
  kind text not null check (kind in ('viewed','saved_home','saved_search','showing_request','registered')),
  mls_number text, address text, price_cents bigint,
  occurred_at timestamptz not null default now(),
  source_event_id text unique,         -- stops the same event being saved twice
  created_at timestamptz not null default now()
);
create index on events (contact_id, occurred_at desc);
create index on events (contact_id, mls_number);

-- Notes: the timeline
create table notes (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references contacts(id) on delete cascade,
  agent_id uuid references agents(id) on delete set null,
  kind text not null check (kind in ('note','call','email','text')),
  body text,
  created_at timestamptz not null default now()
);
create index on notes (contact_id, created_at desc);

-- Tasks: calls and to-dos
create table tasks (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid references contacts(id) on delete cascade,
  agent_id uuid not null references agents(id) on delete cascade,
  title text not null,
  due_at timestamptz not null,
  status text not null default 'open' check (status in ('open','done','snoozed')),
  created_by text not null default 'agent' check (created_by in ('agent','plan','system')),
  created_at timestamptz not null default now()
);
create index on tasks (agent_id, status, due_at);

-- ============================================================
-- HOT-LEAD RULE (Tracy can change the 3 / 7 days here)
-- Runs every time a website event lands.
-- ============================================================
create or replace function flag_hot_lead() returns trigger
language plpgsql security definer as $$
declare
  view_count int;
  reason text;
begin
  if new.kind in ('saved_home','showing_request') then
    reason := case new.kind
      when 'saved_home' then 'Saved ' || coalesce(new.address, 'a home')
      else 'Asked for a showing on ' || coalesce(new.address, 'a home') end;
  elsif new.kind = 'viewed' and new.mls_number is not null then
    select count(*) into view_count
      from events
     where contact_id = new.contact_id
       and mls_number = new.mls_number
       and kind = 'viewed'
       and occurred_at > now() - interval '7 days';
    if view_count >= 3 then
      reason := 'Looked at ' || coalesce(new.address, new.mls_number) || ' ' || view_count || ' times this week';
    end if;
  end if;

  if reason is not null then
    update contacts
       set is_hot = true, hot_reason = reason, hot_at = now(), updated_at = now()
     where id = new.contact_id;
  end if;
  return new;
end $$;

create trigger events_flag_hot after insert on events
  for each row execute function flag_hot_lead();

-- ============================================================
-- WHO SEES WHAT (enforced by the database itself)
-- Agents: their own contacts + their office pond. Broker/admin: everything.
-- Bots use the service key, which skips these rules.
-- ============================================================
create or replace function me() returns agents
language sql stable security definer as $$
  select * from agents where auth_user_id = auth.uid() limit 1
$$;

alter table contacts enable row level security;
alter table events   enable row level security;
alter table notes    enable row level security;
alter table tasks    enable row level security;
alter table agents   enable row level security;
alter table ponds    enable row level security;
alter table companies enable row level security;
alter table offices   enable row level security;

create policy contacts_read on contacts for select using (
  (me()).role in ('broker','admin')
  or owner_agent_id = (me()).id
  or pond_id in (select id from ponds where office_id = (me()).office_id)
);
create policy contacts_write on contacts for update using (
  (me()).role in ('broker','admin') or owner_agent_id = (me()).id
  or pond_id in (select id from ponds where office_id = (me()).office_id)   -- lets an agent claim from the pond
);

create policy events_read on events for select using (
  contact_id in (select id from contacts)   -- inherits the contacts rule
);
create policy notes_read  on notes for select using (contact_id in (select id from contacts));
create policy notes_add   on notes for insert with check (contact_id in (select id from contacts) and agent_id = (me()).id);
create policy tasks_rw    on tasks for all using ((me()).role in ('broker','admin') or agent_id = (me()).id)
                                     with check ((me()).role in ('broker','admin') or agent_id = (me()).id);
-- Roster, ponds, offices, companies: readable only once signed in
create policy agents_read    on agents    for select to authenticated using (true);
create policy ponds_read     on ponds     for select to authenticated using (true);
create policy offices_read   on offices   for select to authenticated using (true);
create policy companies_read on companies for select to authenticated using (true);

-- ============================================================
-- Starter rows for the test
-- ============================================================
insert into companies (name) values ('Blue Ribbon Realty'), ('Blue Ribbon Title and Escrow'),
  ('Blue Ribbon School of Real Estate'), ('Revolution Mortgage');

insert into offices (company_id, name, state)
select c.id, o.name, o.state from companies c,
  (values ('Martinsburg','WV'), ('Front Royal','VA'), ('Bowie','MD'), ('Referral','WV')) o(name, state)
where c.name = 'Blue Ribbon Realty';

insert into ponds (company_id, office_id, name)
select o.company_id, o.id, o.name || ' office leads' from offices o where o.name <> 'Referral';

insert into agents (company_id, office_id, agent_number, full_name, email, role)
select c.id, o.id, '1100511', 'Tracy Adams', 'tracy@blueribbonrealty.com', 'admin'
from companies c join offices o on o.company_id = c.id
where c.name = 'Blue Ribbon Realty' and o.name = 'Martinsburg';
