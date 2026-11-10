-- When someone signs in for the first time, link them to their roster row by email (loaded 11/10/2026).
-- People not on the roster get a login but see nothing (the who-sees-what rules return no rows).
create or replace function public.link_agent_login() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.agents set auth_user_id = new.id
   where lower(email) = lower(new.email) and auth_user_id is null and active;
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.link_agent_login();
