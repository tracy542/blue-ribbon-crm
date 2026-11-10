-- ============================================================
-- 011 — Roster ⇄ CDA dropdown list (Make store 154925), through the existing ROSTER-001 bot
--   CRM save  → only the changed fields go out (action "save"; ROSTER-001 checks them and keeps every other field)
--   New agent → ROSTER-002 (adds one record with the agent ID the CRM gave it)
--   Hourly    → read the whole CDA list back (action "list"): new self-entry agents (ACB-006) land in the CRM,
--               and payout numbers changed somewhere else are taken from the CDA list (it's what pays).
-- Sending stays off until app_settings roster_sync_enabled = 'true'. Reading back runs either way.
-- ============================================================
create extension if not exists pg_net;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.settings (key text primary key, value text not null);
-- Filled in once, by hand in the SQL editor (never in the repo):
--   insert into private.settings values ('roster_hook_url','https://hook.us2.make.com/...'), ('roster_hook_code','...'), ('roster_add_url','https://hook.us2.make.com/...')

alter table roster add column if not exists sync_request bigint;
alter table roster add column if not exists sync_tries int not null default 0;

create or replace function private.setting(k text) returns text
language sql stable security definer set search_path = public, private as $$ select value from private.settings where key = k $$;

-- Send waiting rows (called right after a save, and every minute as a backstop)
create or replace function roster_push() returns int
language plpgsql security definer set search_path = public, private as $$
declare r roster; patch jsonb; req bigint; n int := 0;
  url text := private.setting('roster_hook_url'); code text := private.setting('roster_hook_code'); addurl text := private.setting('roster_add_url');
begin
  if coalesce((select value from app_settings where key = 'roster_sync_enabled'), 'false') <> 'true' or url is null then return 0; end if;
  perform set_config('roster.quiet', 'on', true);
  for r in select * from roster where sync_state = 'waiting' order by updated_at limit 20 for update skip locked loop
    if r.in_cda_list then
      select coalesce(jsonb_object_agg(key, d->'crm'), '{}') into patch from jsonb_each(roster_cda_diff(r)) t(key, d);
      if patch = '{}' then
        update roster set sync_state = 'ok', sync_error = '', sync_tries = 0, synced_at = now() where agent_id = r.agent_id;
        continue;
      end if;
      -- first/last ride along so ROSTER-001 keeps the name in step
      patch := patch || jsonb_build_object('first', r.first, 'last', r.last);
      select net.http_post(url, jsonb_build_object('code', code, 'action', 'save', 'key', r.agent_id,
               'patch', patch::text, 'by', left('CRM ' || r.updated_by, 40)),
             headers := '{"Content-Type":"application/json"}', timeout_milliseconds := 20000) into req;
    elsif addurl is not null then
      select net.http_post(addurl, jsonb_build_object('code', code, 'key', r.agent_id,
               'record', (roster_cda_payload(r) || jsonb_build_object('first', r.first, 'last', r.last,
                          'status', r.status, 'plan_name', r.plan_name))::text, 'by', left('CRM ' || r.updated_by, 40)),
             headers := '{"Content-Type":"application/json"}', timeout_milliseconds := 20000) into req;
    else
      continue;
    end if;
    update roster set sync_state = 'sending', sync_request = req, sync_tries = sync_tries + 1, updated_at = updated_at
     where agent_id = r.agent_id;
    n := n + 1;
  end loop;
  perform set_config('roster.quiet', 'off', true);
  return n;
end $$;

-- Read the answers from Make and mark each row
create or replace function roster_collect() returns int
language plpgsql security definer set search_path = public, private, net as $$
declare r record; body jsonb; n int := 0;
begin
  perform set_config('roster.quiet', 'on', true);
  for r in select ro.agent_id, ro.sync_tries, ro.updated_at, h.status_code, h.content, h.error_msg, h.timed_out, h.created
             from roster ro left join net._http_response h on h.id = ro.sync_request
            where ro.sync_state = 'sending' loop
    if r.created is null then
      -- no answer yet; give it 3 minutes, then try again
      if r.updated_at < now() - interval '3 minutes' then
        update roster set sync_state = case when r.sync_tries >= 3 then 'error' else 'waiting' end,
                          sync_error = case when r.sync_tries >= 3 then 'No answer from the CDA list bot' else '' end
         where agent_id = r.agent_id;
      end if;
      continue;
    end if;
    begin body := r.content::jsonb; exception when others then body := null; end;
    if r.status_code = 200 and body ->> 'ok' = 'true' then
      update roster set sync_state = 'ok', sync_error = '', sync_tries = 0, synced_at = now(), in_cda_list = true,
                        cda_record = coalesce(body -> 'agent', cda_record),
                        phone = coalesce(body -> 'agent' ->> 'cell_phone', phone),
                        cda_split_pct = coalesce(body -> 'agent' ->> 'standard_split_pct', cda_split_pct),
                        cda_arf_pct   = coalesce(body -> 'agent' ->> 'arf_pct', cda_arf_pct)
       where agent_id = r.agent_id;
    elsif body ? 'error' then
      -- the bot checked it and said no (bad value, locked 0% ARF…): a person needs to fix it
      update roster set sync_state = 'error', sync_error = left(body ->> 'error', 300) where agent_id = r.agent_id;
    else
      update roster set sync_state = case when r.sync_tries >= 3 then 'error' else 'waiting' end,
                        sync_error = left(coalesce(r.error_msg, 'HTTP ' || r.status_code || ' ' || coalesce(r.content, '')), 300)
       where agent_id = r.agent_id;
    end if;
    n := n + 1;
  end loop;
  perform set_config('roster.quiet', 'off', true);
  return n;
end $$;

-- Ask for the whole CDA list (answer is read on the next run)
create or replace function roster_pull_request() returns bigint
language plpgsql security definer set search_path = public, private as $$
declare req bigint; url text := private.setting('roster_hook_url');
begin
  if url is null then return null; end if;
  select net.http_post(url, jsonb_build_object('code', private.setting('roster_hook_code'), 'action', 'list'),
         headers := '{"Content-Type":"application/json"}', timeout_milliseconds := 30000) into req;
  insert into private.settings values ('roster_list_request', req::text)
    on conflict (key) do update set value = excluded.value;
  return req;
end $$;

-- Use the CDA list answer: add self-entry agents, keep payout numbers and the saved copy current
create or replace function roster_pull_apply() returns jsonb
language plpgsql security definer set search_path = public, private, net as $$
declare req bigint := nullif(private.setting('roster_list_request'), '')::bigint; body jsonb; a jsonb; added int := 0; changed int := 0; nm text[];
begin
  if req is null then return jsonb_build_object('note', 'no list asked for yet'); end if;
  select content::jsonb into body from net._http_response where id = req and status_code = 200;
  if body is null or body ->> 'ok' <> 'true' then return jsonb_build_object('note', 'no good answer yet'); end if;
  perform set_config('roster.quiet', 'on', true);
  for a in select * from jsonb_array_elements(body -> 'agents') loop
    continue when coalesce(a ->> 'agent_id', '') !~ '^[0-9]{7}$';
    if not exists (select 1 from roster where agent_id = a ->> 'agent_id') then
      nm := regexp_split_to_array(trim(coalesce(a ->> 'name', '')), '\s+');
      insert into roster (agent_id, first, last, email, phone, office, status, mls_id, licenses, mailing,
                          cda_split_pct, cda_arf_pct, in_cda_list, cda_record, source, sync_state, updated_by)
      values (a ->> 'agent_id', coalesce(nullif(a ->> 'first', ''), nm[1], ''),
              coalesce(nullif(a ->> 'last', ''), array_to_string(nm[2:], ' '), ''),
              coalesce(a ->> 'email', ''), coalesce(a ->> 'cell_phone', ''),
              case when a ->> 'office' in ('MBG','FR','Bow','REF') then a ->> 'office' else '' end,
              case when a ->> 'active' = 'false' then 'inactive' when a ->> 'office' = 'REF' then 'referral' else 'active' end,
              coalesce(a ->> 'mls_agent_id', ''),
              coalesce((select jsonb_agg(jsonb_build_object('state', coalesce(s.st, ''), 'number', n.num, 'exp', ''))
                          from unnest(string_to_array(a ->> 'license_numbers', ', ')) with ordinality n(num, i)
                          left join unnest(string_to_array(a ->> 'license_state', ', ')) with ordinality s(st, j) on i = j
                         where coalesce(n.num, '') <> ''), '[]'),
              coalesce(a ->> 'mailing_address', ''), a ->> 'standard_split_pct', a ->> 'arf_pct', true, a,
              'CDA list (agent self-entry)', 'ok', 'CDA list');
      added := added + 1;
    else
      update roster set cda_record = a,
                        in_cda_list = true,
                        -- payout numbers: the CDA list wins unless a CRM change is on its way out
                        cda_split_pct = case when sync_state = 'ok' then a ->> 'standard_split_pct' else cda_split_pct end,
                        cda_arf_pct   = case when sync_state = 'ok' then a ->> 'arf_pct' else cda_arf_pct end
       where agent_id = a ->> 'agent_id'
         and (cda_record is distinct from a);
      if found then changed := changed + 1; end if;
    end if;
  end loop;
  perform set_config('roster.quiet', 'off', true);
  delete from private.settings where key = 'roster_list_request';
  return jsonb_build_object('added', added, 'refreshed', changed);
end $$;

-- After a save that queued a CDA update, send it right away
create or replace function roster_after_queue() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.sync_state = 'waiting' and coalesce(current_setting('roster.quiet', true), 'off') <> 'on' then perform roster_push(); end if;
  return null;
end $$;
drop trigger if exists roster_after_queue on roster;
create trigger roster_after_queue after insert or update on roster
  for each row execute function roster_after_queue();

-- Flag: the CDA list and the CRM disagree on something (someone changed the CDA list elsewhere)
create or replace view roster_flags with (security_invoker = true) as
select r.agent_id,
  array_remove(array[
    case when r.status <> 'inactive' and nullif(r.cda_split_pct, '') is not null and r.split_pct is not null
          and nullif(r.cda_split_pct, '')::numeric is distinct from r.split_pct
         then 'CDA split ' || r.cda_split_pct || '% vs plan ' || trim_scale(r.split_pct) || '%' end,
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
    case when r.sync_state = 'ok' and r.cda_record is not null and roster_cda_diff(r) <> '{}'
         then 'CDA list says something different: ' || (select string_agg(k, ', ') from jsonb_object_keys(roster_cda_diff(r)) k) end,
    nullif(r.split_review, '')
  ], null) as flags
from roster r;
grant select on roster_flags to authenticated;

revoke all on function roster_push() from public, anon, authenticated;
revoke all on function roster_collect() from public, anon, authenticated;
revoke all on function roster_pull_request() from public, anon, authenticated;
revoke all on function roster_pull_apply() from public, anon, authenticated;

-- Every minute: read answers, send anything waiting. Every hour at :35: read the CDA list back.
select cron.unschedule(jobid) from cron.job where jobname in ('roster-sync','roster-pull-ask','roster-pull-use');
select cron.schedule('roster-sync',     '* * * * *',  $$select roster_collect(); select roster_push();$$);
select cron.schedule('roster-pull-ask', '35 * * * *', $$select roster_pull_request()$$);
select cron.schedule('roster-pull-use', '37 * * * *', $$select roster_pull_apply()$$);
