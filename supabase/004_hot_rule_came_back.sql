-- HOT-LEAD RULE v2 (loaded 11/10/2026, Tracy's pick): hot when a buyer COMES BACK to the same home
-- on a separate visit (30+ minutes after an earlier view) within 7 days. Refreshes don't count.
-- Saving a home or asking for a showing is still hot right away.
create or replace function flag_hot_lead() returns trigger
language plpgsql security definer set search_path = public as $$
declare reason text; first_seen timestamptz;
begin
  if new.kind in ('saved_home','showing_request') then
    reason := case new.kind when 'saved_home' then 'Saved ' || coalesce(new.address, 'a home')
              else 'Asked for a showing on ' || coalesce(new.address, 'a home') end;
  elsif new.kind = 'viewed' and new.mls_number is not null then
    select min(occurred_at) into first_seen from events
     where contact_id = new.contact_id and mls_number = new.mls_number and kind = 'viewed'
       and id <> new.id
       and occurred_at > new.occurred_at - interval '7 days'
       and occurred_at <= new.occurred_at - interval '30 minutes';
    if first_seen is not null then
      reason := 'Came back to ' || coalesce(new.address, new.mls_number) || ' again (first looked '
                || to_char(first_seen at time zone 'America/New_York', 'Dy Mon FMDD') || ')';
    end if;
  end if;
  if reason is not null then
    update contacts set is_hot = true, hot_reason = reason, hot_at = now(), updated_at = now() where id = new.contact_id;
  end if;
  return new;
end $$;
