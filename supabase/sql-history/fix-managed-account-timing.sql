-- Auth Admin API inserts the user before applying trusted app_metadata.
-- Validate the final row at transaction end and create its profile atomically.
drop trigger kuilu_require_managed_account on auth.users;
drop trigger kuilu_managed_profile on auth.users;
drop function kuilu_private.create_managed_profile();
create or replace function kuilu_private.require_managed_account() returns trigger
language plpgsql security invoker set search_path='' as $$
declare creator uuid; account_name text; account auth.users%rowtype;
begin
 select * into account from auth.users where id=new.id;
 if not found then return null; end if;
 if account.raw_app_meta_data->>'kuilu_provisioned' is distinct from 'true' then
  raise exception '账号由管理员分配，不开放自行注册' using errcode='42501';
 end if;
 creator := (account.raw_app_meta_data->>'kuilu_created_by')::uuid;
 if creator is null or not exists(select 1 from public.kuilu_profiles where id=creator and role='admin') then
  raise exception '仅管理员可分配账号' using errcode='42501';
 end if;
 account_name:=account.raw_app_meta_data->>'kuilu_username';
 if account_name is null or account_name !~ '^[a-z0-9][a-z0-9._-]{2,31}$'
 or account.email is distinct from account_name||'@accounts.kuilu.invalid'
 or account.raw_app_meta_data->>'kuilu_role' is null
 or account.raw_app_meta_data->>'kuilu_role' not in ('customer','china','admin','driver') then
  raise exception '账号资料无效' using errcode='22023';
 end if;
 insert into public.kuilu_profiles(id,role,username)
 values(account.id,account.raw_app_meta_data->>'kuilu_role',account_name);
 return null;
end $$;
revoke all on function kuilu_private.require_managed_account() from public,anon,authenticated;
grant execute on function kuilu_private.require_managed_account() to supabase_auth_admin;
create constraint trigger kuilu_require_managed_account
after insert on auth.users deferrable initially deferred
for each row execute function kuilu_private.require_managed_account();
