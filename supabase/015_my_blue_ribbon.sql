-- ============================================================
-- 015 — My Blue Ribbon screens (Tracy GOAT 11/10/2026; marked UNDER CONSTRUCTION, tabled until Lone Wolf review)
--   * Follow Up Boss-style stages: Lead, Contacted, Appointment, Showing, Under contract, Closed, Nurture, Dead
--     (stored codes kept so nothing else breaks: new_lead=Lead, active=Contacted, sphere=Nurture, client shows as Showing)
--   * deals: one row per deal; "Under contract" asks for 3 things (address, price, closing date)
--   * Broker message strip + Desk menu links read from app_settings (Brokerage side edits them)
-- ============================================================

-- 1) Two new stages
alter table contacts drop constraint if exists contacts_stage_check;
alter table contacts add constraint contacts_stage_check
  check (stage in ('new_lead','active','appointment','showing','client','under_contract','closed','sphere','dead'));

-- 2) Deals
create table if not exists deals (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references companies(id),
  agent_id uuid not null references agents(id),
  contact_id uuid references contacts(id) on delete set null,
  side text not null default 'buyer' check (side in ('buyer','listing','both')),
  address text not null,
  price numeric(12,2),
  closing_date date,
  status text not null default 'under_contract' check (status in ('under_contract','closed','fell_through')),
  mls_number text,                       -- filled in later by the Bright / compliance bots
  closed_at timestamptz,
  -- Same fields as a Follow Up Boss deal, so our CRM can feed FUB (Kiva Home Hub) later without reshaping anything.
  -- FUB name:              ours:
  --   name                 address (we send the address as the deal name)
  --   stageId / pipeline   status + side (buyer -> Buyers pipeline, listing -> Sellers pipeline)
  --   price                price
  --   projectedCloseDate   closing_date
  --   peopleIds            contact_id -> contacts.fub_person_id
  --   userIds              agent_id   -> agents.fub_user_id
  description text,
  commission_value numeric(12,2),        -- FUB commissionValue (total commission on the deal)
  agent_commission numeric(12,2),        -- FUB agentCommission
  team_commission numeric(12,2),         -- FUB teamCommission (brokerage share)
  mutual_acceptance_date date,           -- FUB mutualAcceptanceDate (contract ratified)
  earnest_money_due_date date,           -- FUB earnestMoneyDueDate
  due_diligence_date date,               -- FUB dueDiligenceDate (inspection / contingency deadline)
  final_walk_through_date date,          -- FUB finalWalkThroughDate
  possession_date date,                  -- FUB possessionDate
  fub_deal_id bigint,                    -- set once the deal is sent to FUB
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- deals table may already exist from an earlier run: make sure every FUB column is there
alter table deals add column if not exists description text;
alter table deals add column if not exists commission_value numeric(12,2);
alter table deals add column if not exists agent_commission numeric(12,2);
alter table deals add column if not exists team_commission numeric(12,2);
alter table deals add column if not exists mutual_acceptance_date date;
alter table deals add column if not exists earnest_money_due_date date;
alter table deals add column if not exists due_diligence_date date;
alter table deals add column if not exists final_walk_through_date date;
alter table deals add column if not exists possession_date date;
alter table deals add column if not exists fub_deal_id bigint;
alter table contacts add column if not exists fub_person_id bigint;   -- FUB person id, for peopleIds
alter table agents   add column if not exists fub_user_id bigint;     -- FUB user id, for userIds
create index if not exists deals_agent_idx on deals (agent_id, status);
alter table deals enable row level security;
drop policy if exists deals_read on deals;
create policy deals_read on deals for select to authenticated using (is_boss() or agent_id = (me()).id);
drop policy if exists deals_boss on deals;
create policy deals_boss on deals for all to authenticated using (is_boss()) with check (is_boss());

-- 3) Change a lead's stage. Under contract needs address, price and closing date and starts a deal.
create or replace function set_stage(p_contact uuid, p_stage text, p_address text default null,
                                     p_price numeric default null, p_close date default null,
                                     p_side text default 'buyer') returns jsonb
language plpgsql security definer set search_path = public as $$
declare a agents; c contacts; d uuid;
begin
  select * into a from agents where auth_user_id = auth.uid() and active;
  if a.id is null then return jsonb_build_object('ok', false, 'error', 'not on the roster'); end if;
  select * into c from contacts where id = p_contact and (a.role in ('broker','admin') or owner_agent_id = a.id);
  if c.id is null then return jsonb_build_object('ok', false, 'error', 'not your lead'); end if;
  if p_stage not in ('new_lead','active','appointment','showing','under_contract','closed','sphere','dead') then
    return jsonb_build_object('ok', false, 'error', 'unknown stage'); end if;

  if p_stage = 'under_contract' then
    if nullif(trim(coalesce(p_address,'')),'') is null or p_price is null or p_close is null then
      return jsonb_build_object('ok', false, 'error', 'Fill in the address, price and closing date'); end if;
    insert into deals (company_id, agent_id, contact_id, side, address, price, closing_date)
    values (c.company_id, coalesce(c.owner_agent_id, a.id), c.id,
            case when p_side in ('buyer','listing','both') then p_side else 'buyer' end,
            trim(p_address), p_price, p_close)
    returning id into d;
  elsif p_stage = 'closed' then
    update deals set status = 'closed', closed_at = now(), updated_at = now()
     where contact_id = c.id and status = 'under_contract';
  elsif c.stage = 'under_contract' and p_stage <> 'under_contract' then
    update deals set status = 'fell_through', updated_at = now()     -- moved back: deal fell through
     where contact_id = c.id and status = 'under_contract';
  end if;

  update contacts set stage = p_stage, updated_at = now() where id = c.id;
  insert into notes (contact_id, agent_id, kind, body) values (c.id, a.id, 'note', 'Stage changed to ' ||
    case p_stage when 'new_lead' then 'Lead' when 'active' then 'Contacted' when 'appointment' then 'Appointment'
      when 'showing' then 'Showing' when 'under_contract' then 'Under contract' when 'closed' then 'Closed'
      when 'sphere' then 'Nurture' else 'Dead' end);
  return jsonb_build_object('ok', true, 'deal_id', d);
end $$;
revoke all on function set_stage(uuid, text, text, numeric, date, text) from public, anon;
grant execute on function set_stage(uuid, text, text, numeric, date, text) to authenticated;

-- 4) Everyone signed in can read the broker message and the Desk menu links (only the broker side can change them)
insert into app_settings (key, value) values
  ('broker_message', 'Only mark someone a Client after the buyer agency or listing agreement is signed. New office leads must be contacted within 48 hours or they go back to the pond.'),
  ('desk_links', '{}')
on conflict (key) do nothing;
drop policy if exists settings_read_desk on app_settings;
create policy settings_read_desk on app_settings for select to authenticated
  using (key in ('broker_message','desk_links'));
