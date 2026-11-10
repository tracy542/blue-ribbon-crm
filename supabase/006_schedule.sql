-- Scheduled jobs inside Supabase (free; no outside service).
-- Hourly at :05 — follow-up plan steps + 48-hour return to pond.
-- Daily 12:00 UTC (7:00 a.m. Eastern in winter, 8:00 a.m. in summer) — build morning emails (HELD).
create extension if not exists pg_cron;
select cron.unschedule(jobid) from cron.job where jobname in ('crm-hourly','crm-morning-email');
select cron.schedule('crm-hourly',        '5 * * * *', $$select public.run_hourly()$$);
select cron.schedule('crm-morning-email', '0 12 * * *', $$select public.build_morning_emails()$$);
