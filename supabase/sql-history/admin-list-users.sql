create schema if not exists kuilu_private;
revoke all on schema kuilu_private from public,anon;
grant usage on schema kuilu_private to authenticated;
create function kuilu_private.list_users(p_search text default '',p_offset integer default 0,p_limit integer default 50)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb; search_term text:=trim(coalesce(p_search,'')); caller uuid:=auth.uid();
begin
 if caller is null or not exists(select 1 from public.kuilu_profiles p where p.id=caller and p.role='admin') then
  raise exception '仅管理员可查看用户账号' using errcode='42501';
 end if;
 if length(search_term)>100 or p_offset is null or p_offset<0 or p_offset>1000000 or p_limit is null or p_limit<1 or p_limit>100 then
  raise exception '查询参数无效' using errcode='22023';
 end if;
 select jsonb_build_object('total',(select count(*) from auth.users u where strpos(lower(coalesce(u.email,'')),lower(search_term))>0),
 'users',coalesce((select jsonb_agg(to_jsonb(x)) from (
 select u.id,u.email,p.role as business_role,u.email_confirmed_at is not null as email_verified,u.created_at,u.last_sign_in_at
 from auth.users u left join public.kuilu_profiles p on p.id=u.id
 where strpos(lower(coalesce(u.email,'')),lower(search_term))>0
 order by u.created_at desc,u.id limit p_limit offset p_offset
 ) x),'[]'::jsonb)) into result;
 return result;
end $$;
revoke all on function kuilu_private.list_users(text,integer,integer) from public,anon;
grant execute on function kuilu_private.list_users(text,integer,integer) to authenticated;
create function public.kuilu_list_users(p_search text default '',p_offset integer default 0,p_limit integer default 50)
returns jsonb language sql stable security invoker set search_path='' as $$
 select kuilu_private.list_users(p_search,p_offset,p_limit);
$$;
revoke all on function public.kuilu_list_users(text,integer,integer) from public,anon;
grant execute on function public.kuilu_list_users(text,integer,integer) to authenticated;
notify pgrst,'reload schema';
