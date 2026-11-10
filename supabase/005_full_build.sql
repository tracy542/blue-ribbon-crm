-- ============================================================
-- Blue Ribbon CRM — full build (11/10/2026)
-- Adds: lead routing, claim from pond, log call + next task, follow-up plans,
-- email queue (HELD until Tracy turns sending on), morning email builder,
-- 48-hour return to pond, broker reports.
-- ============================================================

-- ---------- Contacts: track first contact and pond claims ----------
alter table contacts add column if not exists assigned_at timestamptz;
alter table contacts add column if not exists first_contacted_at timestamptz;
alter table contacts add column if not exists claimed_from_pond_id uuid references ponds(id) on delete set null;
alter table contacts add column if not exists zip text;
create index if not exists contacts_last_contacted on contacts (owner_agent_id, last_contacted_at);
create index if not exists contacts_created on contacts (created_at desc);

-- ---------- Settings (one switch for now: emails stay held) ----------
create table if not exists app_settings (
  key text primary key,
  value text not null,
  updated_at timestamptz not null default now()
);
insert into app_settings (key, value) values ('emails_enabled', 'false') on conflict (key) do nothing;
insert into app_settings (key, value) values ('pond_return_hours', '48') on conflict (key) do nothing;

-- ---------- Follow-up plans ----------
create table if not exists action_plans (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists action_plan_steps (
  id uuid primary key default gen_random_uuid(),
  plan_id uuid not null references action_plans(id) on delete cascade,
  step_no int not null,
  day_offset int not null check (day_offset >= 0),
  kind text not null check (kind in ('email','task')),
  subject text,          -- email subject
  body text,             -- email text (plain-spoken, Tracy's voice); {first_name} gets filled in
  task_title text,       -- task wording; {first_name} gets filled in
  unique (plan_id, step_no)
);
create table if not exists enrollments (
  id uuid primary key default gen_random_uuid(),
  contact_id uuid not null references contacts(id) on delete cascade,
  plan_id uuid not null references action_plans(id) on delete cascade,
  current_step int not null default 1,
  started_at timestamptz not null default now(),
  next_run_at timestamptz,
  status text not null default 'active' check (status in ('active','paused','done','stopped')),
  created_at timestamptz not null default now(),
  unique (contact_id, plan_id)
);
create index if not exists enrollments_due on enrollments (status, next_run_at);
alter table tasks add column if not exists enrollment_id uuid references enrollments(id) on delete set null;

-- ---------- Lead flow rules (first match wins, lowest priority number first) ----------
create table if not exists lead_flow_rules (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  priority int not null,
  label text not null,                  -- plain words shown on the admin page
  match_source text,                    -- e.g. 'Blue Ribbon Homes'; null = any
  match_zip_prefix text,                -- e.g. '226' (Front Royal area); null = any
  to_agent_id uuid references agents(id) on delete set null,
  to_pond_id uuid references ponds(id) on delete set null,
  start_plan_id uuid references action_plans(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  check (to_agent_id is not null or to_pond_id is not null)
);

-- ---------- Email queue: nothing leaves until emails_enabled = true ----------
create table if not exists email_outbox (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('morning','plan','new_lead')),
  to_email text not null,
  to_name text,
  subject text not null,
  body text not null,
  contact_id uuid references contacts(id) on delete set null,
  agent_id uuid references agents(id) on delete set null,
  status text not null default 'held' check (status in ('held','queued','sent','failed','skipped')),
  error text,
  created_at timestamptz not null default now(),
  sent_at timestamptz
);
create index if not exists outbox_status on email_outbox (status, created_at);

-- ---------- Who sees what for the new tables ----------
alter table app_settings      enable row level security;
alter table action_plans      enable row level security;
alter table action_plan_steps enable row level security;
alter table enrollments       enable row level security;
alter table lead_flow_rules   enable row level security;
alter table email_outbox      enable row level security;

create or replace function is_boss() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('broker','admin') from agents where auth_user_id = auth.uid() limit 1), false)
$$;

create policy settings_boss   on app_settings      for all to authenticated using (is_boss()) with check (is_boss());
create policy plans_read      on action_plans      for select to authenticated using (true);
create policy plans_boss      on action_plans      for all to authenticated using (is_boss()) with check (is_boss());
create policy steps_read      on action_plan_steps for select to authenticated using (true);
create policy steps_boss      on action_plan_steps for all to authenticated using (is_boss()) with check (is_boss());
create policy enroll_read     on enrollments       for select to authenticated using (contact_id in (select id from contacts));
create policy enroll_boss     on enrollments       for all to authenticated using (is_boss()) with check (is_boss());
create policy rules_read      on lead_flow_rules   for select to authenticated using (is_boss());
create policy rules_boss      on lead_flow_rules   for all to authenticated using (is_boss()) with check (is_boss());
create policy outbox_boss     on email_outbox      for all to authenticated using (is_boss()) with check (is_boss());
create policy agents_boss_write on agents          for all to authenticated using (is_boss()) with check (is_boss());

-- ---------- Helper: fill {first_name} ----------
create or replace function fill_name(t text, fname text) returns text
language sql immutable as $$ select replace(coalesce(t,''), '{first_name}', coalesce(nullif(fname,''), 'there')) $$;

-- ---------- Start a plan for a contact ----------
create or replace function enroll_contact(p_contact uuid, p_plan uuid) returns void
language plpgsql security definer set search_path = public as $$
declare first_offset int;
begin
  select day_offset into first_offset from action_plan_steps where plan_id = p_plan order by step_no limit 1;
  if first_offset is null then return; end if;
  insert into enrollments (contact_id, plan_id, current_step, next_run_at)
  values (p_contact, p_plan, 1, now() + make_interval(days => first_offset))
  on conflict (contact_id, plan_id) do nothing;
end $$;

-- ---------- Route a brand-new lead by the rules ----------
create or replace function route_new_lead(p_contact uuid) returns void
language plpgsql security definer set search_path = public as $$
declare c contacts; r lead_flow_rules;
begin
  select * into c from contacts where id = p_contact;
  select * into r from lead_flow_rules
   where active and company_id = c.company_id
     and (match_source is null or lower(match_source) = lower(coalesce(c.source,'')))
     and (match_zip_prefix is null or coalesce(c.zip,'') like match_zip_prefix || '%')
   order by priority limit 1;
  if r.id is null then return; end if;                 -- no rule: stays where intake put it
  if r.to_agent_id is not null then
    update contacts set owner_agent_id = r.to_agent_id, pond_id = null, assigned_at = now(), updated_at = now() where id = p_contact;
  else
    update contacts set pond_id = r.to_pond_id, owner_agent_id = null, updated_at = now() where id = p_contact;
  end if;
  if r.start_plan_id is not null then perform enroll_contact(p_contact, r.start_plan_id); end if;
end $$;

-- ---------- Website intake (replaces 002): now routes new leads and records zip ----------
create or replace function ingest_idx_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid; co uuid; pond uuid; is_new boolean := false;
        em text := lower(nullif(trim(p->>'email'),''));
        z text := substring(coalesce(p->>'address','') from '([0-9]{5})(?:-[0-9]{4})?\s*$');
begin
  if em is null then return jsonb_build_object('ok', false, 'error', 'no email'); end if;
  if coalesce(p->>'kind','') not in ('viewed','saved_home','saved_search','showing_request','registered') then
    return jsonb_build_object('ok', false, 'error', 'bad kind'); end if;
  select id into co from companies where name = 'Blue Ribbon Realty';
  select id into cid from contacts where company_id = co and lower(email) = em;
  if cid is null then
    select p2.id into pond from ponds p2 join offices o on o.id = p2.office_id where o.name = 'Martinsburg';
    insert into contacts (company_id, pond_id, email, first_name, last_name, phone, source, idx_lead_id, zip)
    values (co, pond, em, p->>'first_name', p->>'last_name', p->>'phone', coalesce(p->>'source','Website'), p->>'idx_lead_id', z)
    returning id into cid;
    is_new := true;
  end if;
  if is_new then perform route_new_lead(cid); end if;
  insert into events (contact_id, kind, mls_number, address, price_cents, occurred_at, source_event_id)
  values (cid, p->>'kind', p->>'mls_number', p->>'address',
          case when coalesce(p->>'price','') ~ '^[0-9]+$' then (p->>'price')::bigint * 100 end,
          coalesce((p->>'at')::timestamptz, now()), p->>'source_event_id')
  on conflict (source_event_id) do nothing;
  return (select jsonb_build_object('ok', true, 'contact_id', id, 'is_hot', is_hot, 'hot_reason', hot_reason, 'new', is_new)
            from contacts where id = cid);
end $$;
revoke all on function ingest_idx_event(jsonb) from public;
grant execute on function ingest_idx_event(jsonb) to anon, authenticated;

-- ---------- Agent takes a lead from the pond ----------
create or replace function claim_lead(p_contact uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a agents; c contacts;
begin
  select * into a from agents where auth_user_id = auth.uid() and active;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'not on the roster'); end if;
  select * into c from contacts where id = p_contact for update;
  if c.id is null or c.pond_id is null then return jsonb_build_object('ok', false, 'error', 'already taken'); end if;
  if a.role not in ('broker','admin') and c.pond_id not in (select id from ponds where office_id = a.office_id) then
    return jsonb_build_object('ok', false, 'error', 'not your office pond'); end if;
  update contacts set owner_agent_id = a.id, claimed_from_pond_id = c.pond_id, pond_id = null,
         assigned_at = now(), updated_at = now() where id = p_contact;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function claim_lead(uuid) to authenticated;

-- ---------- Log a call/email/note and set the next task, in one step ----------
create or replace function log_activity(p_contact uuid, p_kind text, p_body text,
                                        p_next_title text default null, p_next_due timestamptz default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a agents;
begin
  select * into a from agents where auth_user_id = auth.uid() and active;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'not on the roster'); end if;
  if not exists (select 1 from contacts where id = p_contact
                  and (a.role in ('broker','admin') or owner_agent_id = a.id)) then
    return jsonb_build_object('ok', false, 'error', 'not your lead'); end if;
  if p_kind not in ('note','call','email','text') then return jsonb_build_object('ok', false, 'error', 'bad kind'); end if;
  insert into notes (contact_id, agent_id, kind, body) values (p_contact, a.id, p_kind, nullif(trim(coalesce(p_body,'')),''));
  if p_kind in ('call','email','text') then
    update contacts set last_contacted_at = now(),
           first_contacted_at = coalesce(first_contacted_at, now()),
           stage = case when stage = 'new_lead' then 'active' else stage end,
           updated_at = now()
     where id = p_contact;
  end if;
  if nullif(trim(coalesce(p_next_title,'')),'') is not null then
    insert into tasks (contact_id, agent_id, title, due_at, created_by)
    values (p_contact, a.id, trim(p_next_title), coalesce(p_next_due, now() + interval '1 day'), 'agent');
  end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function log_activity(uuid, text, text, text, timestamptz) to authenticated;

-- ---------- Hourly job: plan steps + 48-hour return to pond ----------
create or replace function run_hourly() returns jsonb
language plpgsql security definer set search_path = public as $$
declare e record; s action_plan_steps; c contacts; ag agents; nxt action_plan_steps;
        n_tasks int := 0; n_emails int := 0; n_returned int := 0; hrs int;
begin
  for e in select * from enrollments where status = 'active' and next_run_at <= now() order by next_run_at limit 500 loop
    select * into s from action_plan_steps where plan_id = e.plan_id and step_no = e.current_step;
    select * into c from contacts where id = e.contact_id;
    if s.id is null or c.id is null or c.stage in ('closed','dead') then
      update enrollments set status = 'done', next_run_at = null where id = e.id; continue;
    end if;
    select * into ag from agents where id = c.owner_agent_id;
    if ag.id is null then continue; end if;        -- still in a pond: wait until an agent takes it
    if s.kind = 'task' then
      insert into tasks (contact_id, agent_id, title, due_at, created_by, enrollment_id)
      values (c.id, ag.id, fill_name(s.task_title, c.first_name), now(), 'plan', e.id);
      n_tasks := n_tasks + 1;
    elsif s.kind = 'email' and c.email is not null then
      insert into email_outbox (kind, to_email, to_name, subject, body, contact_id, agent_id)
      values ('plan', c.email, trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')),
              fill_name(s.subject, c.first_name), fill_name(s.body, c.first_name), c.id, ag.id);
      insert into notes (contact_id, agent_id, kind, body)
      values (c.id, ag.id, 'note', 'Follow-up plan email written, held (not sent yet): ' || fill_name(s.subject, c.first_name));
      n_emails := n_emails + 1;
    end if;
    select * into nxt from action_plan_steps where plan_id = e.plan_id and step_no > e.current_step order by step_no limit 1;
    if nxt.id is null then
      update enrollments set status = 'done', next_run_at = null where id = e.id;
    else
      update enrollments set current_step = nxt.step_no,
             next_run_at = e.started_at + make_interval(days => nxt.day_offset) where id = e.id;
    end if;
  end loop;

  -- Office leads taken from a pond but never contacted go back after N hours
  select value::int into hrs from app_settings where key = 'pond_return_hours';
  with gone as (
    select id, owner_agent_id from contacts
     where claimed_from_pond_id is not null and first_contacted_at is null
       and assigned_at < now() - make_interval(hours => coalesce(hrs, 48))
     for update),
  back as (
    update contacts ct set pond_id = ct.claimed_from_pond_id, owner_agent_id = null, claimed_from_pond_id = null,
           assigned_at = null, updated_at = now()
      from gone where ct.id = gone.id
    returning ct.id),
  closed as (                                   -- the old agent's open tasks for it close too
    update tasks tk set status = 'done'
      from gone where tk.contact_id = gone.id and tk.agent_id = gone.owner_agent_id and tk.status = 'open'
    returning tk.id)
  select count(*) into n_returned from back;

  return jsonb_build_object('tasks', n_tasks, 'emails_queued', n_emails, 'returned_to_pond', n_returned);
end $$;

-- ---------- Daily job: build each agent's 7 a.m. email (held until sending is on) ----------
create or replace function build_morning_emails() returns int
language plpgsql security definer set search_path = public as $$
declare a record; hot_lines text; task_count int; late_count int; n int := 0; body text; subj text; hot_count int;
begin
  for a in select * from agents where active loop
    select count(*), string_agg('- ' || trim(coalesce(first_name,'') || ' ' || coalesce(last_name,'')) || ': ' || hot_reason, E'\n' order by hot_at desc)
      into hot_count, hot_lines
      from (select * from contacts where owner_agent_id = a.id and is_hot order by hot_at desc limit 5) h;
    select count(*), count(*) filter (where due_at < date_trunc('day', now() at time zone 'America/New_York') at time zone 'America/New_York')
      into task_count, late_count
      from tasks where agent_id = a.id and status = 'open'
       and due_at < (date_trunc('day', now() at time zone 'America/New_York') + interval '1 day') at time zone 'America/New_York';
    if coalesce(hot_count,0) = 0 and coalesce(task_count,0) = 0 then continue; end if;
    subj := split_part(a.full_name, ' ', 1) || ', ' ||
            case when hot_count > 0 then hot_count || ' hot lead' || case when hot_count > 1 then 's' else '' end || ' and ' else '' end ||
            task_count || ' call' || case when task_count = 1 then '' else 's' end || ' today';
    body := case when hot_count > 0 then 'These leads were on the website looking hard. Start with them.' || E'\n\n' || hot_lines || E'\n\n' else '' end ||
            'Due today: ' || task_count || case when late_count > 0 then ' (' || late_count || ' overdue)' else '' end || '.' || E'\n\n' ||
            'Open My Desk: https://blue-ribbon-crm.vercel.app' || E'\n\n' ||
            'No password needed. Questions? Email Tracy.';
    insert into email_outbox (kind, to_email, to_name, subject, body, agent_id) values ('morning', a.email, a.full_name, subj, body, a.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- Broker reports (boss only) ----------
create or replace function broker_unworked() returns table (agent_id uuid, agent_name text, office text, unworked int, oldest timestamptz)
language sql stable security definer set search_path = public as $$
  select a.id, a.full_name, o.name, count(c.id)::int, min(coalesce(c.assigned_at, c.created_at))
    from contacts c join agents a on a.id = c.owner_agent_id left join offices o on o.id = a.office_id
   where is_boss() and c.first_contacted_at is null and c.stage not in ('closed','dead')
   group by a.id, a.full_name, o.name
   order by count(c.id) desc, min(coalesce(c.assigned_at, c.created_at))
$$;
create or replace function broker_summary() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not is_boss() then null else jsonb_build_object(
    'unworked', (select count(*) from contacts where first_contacted_at is null and stage not in ('closed','dead')),
    'in_ponds', (select count(*) from contacts where pond_id is not null),
    'median_minutes_to_first_contact', (select round(extract(epoch from percentile_cont(0.5) within group
         (order by first_contacted_at - coalesce(assigned_at, created_at))) / 60)
         from contacts where first_contacted_at is not null and created_at > now() - interval '30 days'),
    'sources', (select coalesce(jsonb_agg(jsonb_build_object('source', source, 'leads', n) order by n desc), '[]'::jsonb)
                  from (select coalesce(source,'Unknown') source, count(*) n from contacts
                         where created_at > now() - interval '30 days' group by 1) s),
    'ponds', (select coalesce(jsonb_agg(jsonb_build_object('pond', p.name, 'waiting', (select count(*) from contacts c where c.pond_id = p.id)) order by p.name), '[]'::jsonb) from ponds p)
  ) end
$$;
grant execute on function broker_unworked() to authenticated;
grant execute on function broker_summary() to authenticated;
revoke all on function run_hourly() from public, anon, authenticated;
revoke all on function build_morning_emails() from public, anon, authenticated;
revoke all on function route_new_lead(uuid) from public, anon, authenticated;
revoke all on function enroll_contact(uuid, uuid) from public, anon, authenticated;

-- ---------- Starter content ----------
-- Plan: plain-spoken, Tracy's voice, no hype. Emails stay HELD until Tracy reads and OKs them.
insert into action_plans (company_id, name)
select id, 'New buyer lead, 30 days' from companies where name = 'Blue Ribbon Realty'
on conflict (name) do nothing;

insert into action_plan_steps (plan_id, step_no, day_offset, kind, subject, body, task_title)
select p.id, v.step_no, v.day_offset, v.kind, v.subject, v.body, v.task_title
from action_plans p, (values
  (1, 0, 'task',  null, null, 'Call {first_name} — new website lead'),
  (2, 1, 'email', 'Homes you looked at',
     E'Hi {first_name},\n\nI saw you were looking at homes on our site. If any of them caught your eye, I can get you in to see it this week.\n\nJust reply to this email with the address and a couple of times that work.\n\nThanks,', null),
  (3, 3, 'task',  null, null, 'Follow up with {first_name} — any homes to see?'),
  (4, 7, 'email', 'Still looking?',
     E'Hi {first_name},\n\nChecking in. Are you still looking, or did the timing change?\n\nIf you want, reply with what you want in a home and your price range, and I will set up a search that sends you new listings the day they hit the market.\n\nThanks,', null),
  (5, 14, 'task', null, null, 'Check in with {first_name}'),
  (6, 30, 'email', 'Checking in',
     E'Hi {first_name},\n\nIt has been about a month. No pressure, just want to make sure you have what you need.\n\nIf now is not the right time, reply and let me know when to check back.\n\nThanks,', null)
) v(step_no, day_offset, kind, subject, body, task_title)
where p.name = 'New buyer lead, 30 days'
on conflict (plan_id, step_no) do nothing;

-- Ponds for the Referral office is intentionally none. Default rule: website leads -> Martinsburg pond + 30-day plan.
insert into lead_flow_rules (company_id, priority, label, match_source, to_pond_id, start_plan_id)
select c.id, 100, 'Blue Ribbon Homes website, any area → Martinsburg pond, start "New buyer lead, 30 days"',
       'Blue Ribbon Homes', p.id, ap.id
from companies c join ponds p on p.name = 'Martinsburg office leads' join action_plans ap on ap.name = 'New buyer lead, 30 days'
where c.name = 'Blue Ribbon Realty'
  and not exists (select 1 from lead_flow_rules where priority = 100);

insert into lead_flow_rules (company_id, priority, label, match_source, match_zip_prefix, to_pond_id, start_plan_id)
select c.id, 50, 'Blue Ribbon Homes website, Virginia 226xx ZIPs → Front Royal pond, start "New buyer lead, 30 days"',
       'Blue Ribbon Homes', '226', p.id, ap.id
from companies c join ponds p on p.name = 'Front Royal office leads' join action_plans ap on ap.name = 'New buyer lead, 30 days'
where c.name = 'Blue Ribbon Realty'
  and not exists (select 1 from lead_flow_rules where priority = 50);

insert into lead_flow_rules (company_id, priority, label, match_source, match_zip_prefix, to_pond_id, start_plan_id)
select c.id, 60, 'Blue Ribbon Homes website, Maryland 207xx ZIPs → Bowie pond, start "New buyer lead, 30 days"',
       'Blue Ribbon Homes', '207', p.id, ap.id
from companies c join ponds p on p.name = 'Bowie office leads' join action_plans ap on ap.name = 'New buyer lead, 30 days'
where c.name = 'Blue Ribbon Realty'
  and not exists (select 1 from lead_flow_rules where priority = 60);
