-- ============================================================
-- 012 — Monthly office fee (Stripe) now lands on the CRM roster
--   Daily: ask ROSTER-003 for the Stripe subscription list, then mark each
--   Bowie / Front Royal active agent: setup / failed / canceled / none.
--   roster_fee_report(secret) gives the monthly report (used by the 2nd-of-month email task).
-- Same rules as the old "Agent fee → roster sync" task.
-- ============================================================
-- private.settings needs: roster_fee_url (ROSTER-003 webhook), report_secret (random text). Never in the repo.

-- "Charlotte L Murphy" -> "charlotte murphy" (first word + last word)
create or replace function norm_name(n text) returns text language sql immutable as $$
  select lower(split_part(trim(coalesce(n, '')), ' ', 1) || ' ' ||
               coalesce((regexp_match(trim(coalesce(n, '')), '(\S+)$'))[1], ''))
$$;

create or replace function roster_fee_request() returns bigint
language plpgsql security definer set search_path = public, private as $$
declare req bigint; url text := private.setting('roster_fee_url');
begin
  if url is null then return null; end if;
  select net.http_post(url, jsonb_build_object('code', private.setting('roster_hook_code')),
         headers := '{"Content-Type":"application/json"}', timeout_milliseconds := 30000) into req;
  insert into private.settings values ('roster_fee_request', req::text) on conflict (key) do update set value = excluded.value;
  return req;
end $$;

-- "Tototto10+1384@Gmail.com" -> "tototto10@gmail.com"
create or replace function norm_email(e text) returns text language sql immutable as $$
  select lower(regexp_replace(trim(coalesce(e, '')), '\+[^@]*@', '@'))
$$;

create or replace function roster_fee_apply() returns jsonb
language plpgsql security definer set search_path = public, private, net as $$
declare req bigint := nullif(private.setting('roster_fee_request'), '')::bigint; body jsonb; changed int := 0; unmatched jsonb;
begin
  if req is null then return jsonb_build_object('note', 'no fee list asked for yet'); end if;
  select content::jsonb into body from net._http_response where id = req and status_code = 200;
  if body is null or body ->> 'ok' <> 'true' then
    insert into private.settings values ('fee_last_error', now()::text || ' no good answer from Stripe list')
      on conflict (key) do update set value = excluded.value;
    return jsonb_build_object('note', 'no good answer from Stripe list');
  end if;
  perform set_config('roster.quiet', 'on', true);
  with subs as (
    select norm_email(s ->> 'email') em, norm_name(s ->> 'name') nm, s ->> 'status' st, s ->> 'created' created
      from jsonb_array_elements(body -> 'subs') s
  ), owe as (
    select r.agent_id, norm_email(r.email) em, norm_name(r.first || ' ' || r.last) nm, r.fee_status from roster r
     where r.status = 'active' and r.office in ('Bow', 'FR')
  ), mapped as (
    select o.agent_id, o.fee_status old,
           case when m.st in ('trialing', 'active') then 'setup'
                when m.st in ('past_due', 'unpaid', 'incomplete') then 'failed'
                when m.st in ('canceled', 'incomplete_expired') then 'canceled'
                else 'none' end new_status,
           coalesce(m.created, '') since
      from owe o
      left join lateral (
        -- email match first; if none, full-name match; newest subscription wins
        select s.st, s.created from subs s
         where (s.em <> '' and s.em = o.em)
            or (s.nm <> '' and s.nm = o.nm and not exists (select 1 from subs s2 where s2.em <> '' and s2.em = o.em))
         order by (s.em = o.em) desc, s.created desc limit 1) m on true
  ), upd as (
    update roster r set fee_status = m.new_status, fee_since = m.since, fee_checked_at = now()::text
      from mapped m where r.agent_id = m.agent_id
    returning (m.old is distinct from m.new_status) as did_change
  )
  select count(*) filter (where did_change) into changed from upd;

  -- Stripe subscribers who match no active Bowie / Front Royal agent
  select coalesce(jsonb_agg(s), '[]') into unmatched from jsonb_array_elements(body -> 'subs') s
   where not exists (select 1 from roster r where r.status = 'active' and r.office in ('Bow', 'FR')
                       and ((norm_email(r.email) <> '' and norm_email(r.email) = norm_email(s ->> 'email'))
                         or norm_name(r.first || ' ' || r.last) = norm_name(s ->> 'name')));
  insert into private.settings values ('fee_unmatched', unmatched::text) on conflict (key) do update set value = excluded.value;
  delete from private.settings where key in ('roster_fee_request', 'fee_last_error');
  perform set_config('roster.quiet', 'off', true);
  return jsonb_build_object('changed', changed, 'unmatched', jsonb_array_length(unmatched));
end $$;

-- Monthly report (callable from the website with the report secret)
create or replace function roster_fee_report(p_secret text) returns jsonb
language plpgsql stable security definer set search_path = public, private as $$
begin
  if p_secret is null or p_secret <> coalesce(private.setting('report_secret'), md5(random()::text)) then
    return jsonb_build_object('ok', false);
  end if;
  return jsonb_build_object('ok', true,
    'checked_at', (select max(fee_checked_at) from roster),
    'stripe_problem', private.setting('fee_last_error'),
    'set_up', (select coalesce(jsonb_agg(trim(first || ' ' || last) order by last), '[]') from roster
                where status = 'active' and office in ('Bow','FR') and fee_override = '' and fee_status = 'setup'),
    'failed_or_canceled', (select coalesce(jsonb_agg(trim(first || ' ' || last) || ' (' || fee_status || ')' order by last), '[]') from roster
                where status = 'active' and office in ('Bow','FR') and fee_override = '' and fee_status in ('failed','canceled')),
    'not_set_up_bowie', (select coalesce(jsonb_agg(trim(first || ' ' || last) order by last), '[]') from roster
                where status = 'active' and office = 'Bow' and fee_override = '' and coalesce(fee_status,'') in ('','none')),
    'not_set_up_front_royal', (select coalesce(jsonb_agg(trim(first || ' ' || last) order by last), '[]') from roster
                where status = 'active' and office = 'FR' and fee_override = '' and coalesce(fee_status,'') in ('','none')),
    'paid_for_year_or_exempt', (select coalesce(jsonb_agg(trim(first || ' ' || last) || ' (' || fee_override || ')' order by last), '[]') from roster
                where status = 'active' and fee_override <> ''),
    'stripe_not_on_roster', coalesce(private.setting('fee_unmatched')::jsonb, '[]'));
end $$;
revoke all on function roster_fee_request() from public, anon, authenticated;
revoke all on function roster_fee_apply() from public, anon, authenticated;
grant execute on function roster_fee_report(text) to anon, authenticated;

-- 8:53 a.m. Eastern ask, 8:58 use (UTC times; Eastern standard time)
select cron.unschedule(jobid) from cron.job where jobname in ('roster-fee-ask','roster-fee-use');
select cron.schedule('roster-fee-ask', '53 13 * * *', $$select roster_fee_request()$$);
select cron.schedule('roster-fee-use', '58 13 * * *', $$select roster_fee_apply()$$);
