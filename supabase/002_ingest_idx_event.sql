-- Front door for website events (already loaded 11/10/2026).
-- Finds or creates the lead by email, saves the event, returns hot status.
-- New leads with no owner go to the Martinsburg office pond.
create or replace function ingest_idx_event(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare cid uuid; co uuid; pond uuid; em text := lower(nullif(trim(p->>'email'),''));
begin
  if em is null then return jsonb_build_object('ok', false, 'error', 'no email'); end if;
  if coalesce(p->>'kind','') not in ('viewed','saved_home','saved_search','showing_request','registered') then
    return jsonb_build_object('ok', false, 'error', 'bad kind'); end if;
  select id into co from companies where name = 'Blue Ribbon Realty';
  select id into cid from contacts where company_id = co and lower(email) = em;
  if cid is null then
    select p2.id into pond from ponds p2 join offices o on o.id = p2.office_id where o.name = 'Martinsburg';
    insert into contacts (company_id, pond_id, email, first_name, last_name, phone, source, idx_lead_id)
    values (co, pond, em, p->>'first_name', p->>'last_name', p->>'phone', coalesce(p->>'source','Website'), p->>'idx_lead_id')
    returning id into cid;
  end if;
  insert into events (contact_id, kind, mls_number, address, price_cents, occurred_at, source_event_id)
  values (cid, p->>'kind', p->>'mls_number', p->>'address',
          case when coalesce(p->>'price','') ~ '^[0-9]+$' then (p->>'price')::bigint * 100 end,
          coalesce((p->>'at')::timestamptz, now()), p->>'source_event_id')
  on conflict (source_event_id) do nothing;
  return (select jsonb_build_object('ok', true, 'contact_id', id, 'is_hot', is_hot, 'hot_reason', hot_reason) from contacts where id = cid);
end $$;
revoke all on function ingest_idx_event(jsonb) from public;
grant execute on function ingest_idx_event(jsonb) to anon, authenticated;
