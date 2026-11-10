# Blue Ribbon CRM (light)

Agents' daily screen (My Desk) on a Supabase database Tracy owns. Website lead views come from IDX Broker.

- `public/index.html` — My Desk. Sign in by emailed link; hot leads first, today's tasks below.
- `api/idx-event.js` — CRM-001: takes each website action from IDX Broker and saves it.
- `api/config.js` — gives My Desk the Supabase address and public key.
- `idx-broker/header-script.html` — pasted into IDX Broker's page wrapper.
- `supabase/` — database setup, in the order loaded.

Hot lead = came back to the same home on a separate visit (30+ min later) within 7 days, or saved a home, or asked for a showing (see supabase/004_hot_rule_came_back.sql).
