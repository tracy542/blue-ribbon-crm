-- Small status line for the roster page: is CDA sending on, how many waiting / failed.
create or replace function roster_sync_status() returns jsonb
language sql stable security definer set search_path = public as $$
  select case when not is_roster_editor() then null else jsonb_build_object(
    'enabled', coalesce((select value from app_settings where key = 'roster_sync_enabled'), 'false') = 'true',
    'waiting', (select count(*) from roster where sync_state in ('waiting','sending')),
    'errors',  (select count(*) from roster where sync_state = 'error')) end
$$;
grant execute on function roster_sync_status() to authenticated;
