alter table public.kuilu_profiles add column username text;
alter table public.kuilu_profiles add constraint kuilu_profiles_username_check check(username is null or username ~ '^[a-z0-9][a-z0-9._-]{2,31}$');
create unique index kuilu_profiles_username_unique on public.kuilu_profiles(username) where username is not null;
insert into public.kuilu_profiles(id,role) select u.id,'customer' from auth.users u where not exists(select 1 from public.kuilu_profiles p where p.id=u.id);
revoke insert on public.kuilu_profiles from authenticated;
drop policy kuilu_profile_create on public.kuilu_profiles;
grant usage on schema kuilu_private to supabase_auth_admin;
grant select,insert on public.kuilu_profiles to supabase_auth_admin;
create policy kuilu_internal_auth_read on public.kuilu_profiles for select to supabase_auth_admin using(true);
create policy kuilu_internal_auth_create on public.kuilu_profiles for insert to supabase_auth_admin with check(true);

create function kuilu_private.require_managed_account() returns trigger
language plpgsql security invoker set search_path='' as $$
declare creator uuid; account_name text;
begin
 if new.raw_app_meta_data->>'kuilu_provisioned' is distinct from 'true' then
  raise exception '账号由管理员分配，不开放自行注册' using errcode='42501';
 end if;
 creator := (new.raw_app_meta_data->>'kuilu_created_by')::uuid;
 if creator is null or not exists(select 1 from public.kuilu_profiles where id=creator and role='admin') then
  raise exception '仅管理员可分配账号' using errcode='42501';
 end if;
 account_name:=new.raw_app_meta_data->>'kuilu_username';
 if account_name is null or account_name !~ '^[a-z0-9][a-z0-9._-]{2,31}$'
 or new.email is distinct from account_name||'@accounts.kuilu.invalid'
 or new.raw_app_meta_data->>'kuilu_role' is null
 or new.raw_app_meta_data->>'kuilu_role' not in ('customer','china','admin','driver') then
  raise exception '账号资料无效' using errcode='22023';
 end if;
 return new;
end $$;
revoke all on function kuilu_private.require_managed_account() from public,anon,authenticated;
create trigger kuilu_require_managed_account before insert on auth.users for each row execute function kuilu_private.require_managed_account();

create function kuilu_private.create_managed_profile() returns trigger
language plpgsql security invoker set search_path='' as $$
begin
 insert into public.kuilu_profiles(id,role,username)
 values(new.id,new.raw_app_meta_data->>'kuilu_role',new.raw_app_meta_data->>'kuilu_username');
 return new;
end $$;
revoke all on function kuilu_private.create_managed_profile() from public,anon,authenticated;
create trigger kuilu_managed_profile after insert on auth.users for each row execute function kuilu_private.create_managed_profile();

create or replace function kuilu_private.list_users(p_search text default '',p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; search_term text:=trim(coalesce(p_search,'')); caller uuid:=auth.uid();
begin
 if caller is null or not exists(select 1 from public.kuilu_profiles p where p.id=caller and p.role='admin') then
  raise exception '仅管理员可查看用户账号' using errcode='42501';
 end if;
 if length(search_term)>100 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit<1 or p_limit>100 then
  raise exception '查询参数无效' using errcode='22023';
 end if;
 select jsonb_build_object('total',(select count(*) from auth.users u left join public.kuilu_profiles p on p.id=u.id where strpos(lower(coalesce(p.username,u.email,'')),lower(search_term))>0),
 'users',coalesce((select jsonb_agg(to_jsonb(x)) from (
 select u.id,case when p.username is null then u.email else null end as email,p.username,p.role as business_role,
 u.created_at,u.last_sign_in_at
 from auth.users u left join public.kuilu_profiles p on p.id=u.id
 where strpos(lower(coalesce(p.username,u.email,'')),lower(search_term))>0
 order by u.created_at desc,u.id limit p_limit offset p_offset
 ) x),'[]'::jsonb)) into result;
 return result;
end $$;
notify pgrst,'reload schema';
