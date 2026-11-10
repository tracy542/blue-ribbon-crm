# Blue Ribbon CRM (light)

Agents' daily screen (My Desk) on a Supabase database Tracy owns. Website lead views come from IDX Broker.

- `public/index.html` — My Desk. Sign in by emailed link; hot leads first, today's tasks below.
- `api/idx-event.js` — CRM-001: takes each website action from IDX Broker and saves it.
- `api/config.js` — gives My Desk the Supabase address and public key.
- `idx-broker/header-script.html` — pasted into IDX Broker's page wrapper.
- `supabase/` — database setup, in the order loaded.

Hot lead = same home viewed 3 times in 7 days, or a home saved, or a showing requested (change in `flag_hot_lead`).
