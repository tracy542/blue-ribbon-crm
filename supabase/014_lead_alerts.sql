-- ============================================================
-- 014 — New-lead alert email to the agent (Tracy GOAT 11/10/2026, wording approved)
--   When a website lead is assigned to an agent, the agent gets one email right away,
--   sent from Tracy's Outlook by Make bot LEAD-001. Retries 3 times, then shows as failed.
--   Only this alert is switched on. Follow-up plan emails to buyers stay HELD.
-- private.settings needs: lead_alert_url (LEAD-001 webhook). Never in the repo.
-- ============================================================
alter table email_outbox add column if not exists request_id bigint;
alter table email_outbox add column if not exists tries int not null default 0;
insert into app_settings (key, value) values ('lead_alerts_enabled', 'true')
  on conflict (key) do update set value = 'true';

-- Send one queued alert through LEAD-001
create or replace function lead_alert_send(p_id uuid) returns void
language plpgsql security definer set search_path = public, private as $$
declare m email_outbox; req bigint; url text := private.setting('lead_alert_url');
begin
  select * into m from email_outbox where id = p_id;
  if m.id is null or url is null or m.status <> 'queued' then return; end if;
  select net.http_post(url, jsonb_build_object('code', private.setting('roster_hook_code'),
           'to', m.to_email, 'subject', m.subject, 'body_html', m.body),
         headers := '{"Content-Type":"application/json"}', timeout_milliseconds := 30000) into req;
  update email_outbox set request_id = req, tries = tries + 1 where id = p_id;
end $$;

-- Write the alert the first time a newly assigned lead shows activity
create or replace function lead_alert_on_event() returns trigger
language plpgsql security definer set search_path = public as $$
declare c contacts; a agents; nm text; what text; place text; price text; body text; subj text; oid uuid;
begin
  if coalesce((select value from app_settings where key = 'lead_alerts_enabled'), 'false') <> 'true' then return new; end if;
  select * into c from contacts where id = new.contact_id;
  if c.owner_agent_id is null or c.assigned_at is null or c.assigned_at < now() - interval '10 minutes' then return new; end if;
  if exists (select 1 from email_outbox where kind = 'new_lead' and contact_id = c.id and agent_id = c.owner_agent_id) then return new; end if;
  select * into a from agents where id = c.owner_agent_id;
  if a.email is null then return new; end if;

  nm    := coalesce(nullif(trim(coalesce(c.first_name,'') || ' ' || coalesce(c.last_name,'')), ''), c.email);
  what  := case new.kind when 'saved_home' then 'saved' when 'showing_request' then 'asked to see' else 'looked at' end;
  place := coalesce(nullif(trim(new.address), ''), 'a home on the site');
  price := case when new.price_cents is not null then ' — $' || to_char(new.price_cents / 100, 'FM999,999,999') else '' end;
  subj  := left('New lead: ' || nm || ' — ' || what || ' ' || split_part(place, ',', 1), 200);
  body  := '<p>' || nm || ' just signed up on blueribbon.homes and was assigned to you.</p><ul>'
        || '<li>' || upper(left(what, 1)) || substr(what, 2) || ': ' || place || price || '</li>'
        || '<li>Email: ' || coalesce(c.email, '—') || '</li>'
        || '<li>Phone: ' || coalesce(nullif(c.phone, ''), '—') || '</li></ul>'
        || '<p>Reach out today. If nobody makes contact within 48 hours, the lead goes back to the office pond.</p>'
        || '<p><a href="https://blue-ribbon-crm.vercel.app/#/p/' || c.id || '">Open the lead</a></p>';

  insert into email_outbox (kind, to_email, to_name, subject, body, contact_id, agent_id, status)
  values ('new_lead', a.email, a.full_name, subj, body, c.id, a.id, 'queued') returning id into oid;
  perform lead_alert_send(oid);
  return new;
end $$;
drop trigger if exists lead_alert_on_event on events;
create trigger lead_alert_on_event after insert on events
  for each row execute function lead_alert_on_event();

-- Every minute: mark sent / retry / failed
create or replace function lead_alert_collect() returns int
language plpgsql security definer set search_path = public, net as $$
declare r record; body jsonb; n int := 0;
begin
  for r in select m.id, m.tries, m.created_at, h.status_code, h.content, h.created
             from email_outbox m left join net._http_response h on h.id = m.request_id
            where m.kind = 'new_lead' and m.status = 'queued' and m.request_id is not null loop
    begin body := r.content::jsonb; exception when others then body := null; end;
    if r.created is null then
      if r.created_at < now() - make_interval(mins => 3 * r.tries) then
        if r.tries >= 3 then update email_outbox set status = 'failed', error = 'No answer from LEAD-001' where id = r.id;
        else perform lead_alert_send(r.id); end if;
      end if;
    elsif r.status_code = 200 and body ->> 'ok' = 'true' then
      update email_outbox set status = 'sent', sent_at = now(), error = null where id = r.id; n := n + 1;
    elsif r.tries >= 3 then
      update email_outbox set status = 'failed', error = left(coalesce(body ->> 'error', 'HTTP ' || r.status_code), 300) where id = r.id;
    else
      perform lead_alert_send(r.id);
    end if;
  end loop;
  return n;
end $$;
revoke all on function lead_alert_send(uuid) from public, anon, authenticated;
revoke all on function lead_alert_collect() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'lead-alerts';
select cron.schedule('lead-alerts', '* * * * *', $$select lead_alert_collect()$$);
