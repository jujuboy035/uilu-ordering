begin;
do $$
declare admin_id uuid; fixture uuid:=gen_random_uuid(); denied boolean; username text:='qa'||substr(replace(gen_random_uuid()::text,'-',''),1,20); meta jsonb; result jsonb;
begin
 select id into admin_id from public.kuilu_profiles where role='admin' limit 1;
 if admin_id is null then raise exception 'missing admin fixture';end if;
 if not has_schema_privilege('supabase_auth_admin','kuilu_private','usage')
 or not has_table_privilege('supabase_auth_admin','public.kuilu_profiles','select')
 or not has_table_privilege('supabase_auth_admin','public.kuilu_profiles','insert') then raise exception 'internal auth grants missing';end if;
 denied:=false;
 begin insert into auth.users(id,email,raw_app_meta_data) values(fixture,username||'@accounts.kuilu.invalid','{}'); set constraints all immediate; exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'public signup not blocked';end if;
 meta:=jsonb_build_object('kuilu_provisioned',true,'kuilu_created_by',admin_id,'kuilu_username',username,'kuilu_role','customer');
 set constraints all deferred;
 -- Reproduce the real Admin API: INSERT defaults, then UPDATE app_metadata.
 insert into auth.users(id,email,raw_app_meta_data) values(fixture,username||'@accounts.kuilu.invalid','{"provider":"email","providers":["email"]}');
 update auth.users set raw_app_meta_data=meta,email_confirmed_at=now() where id=fixture;
 set constraints all immediate;
 execute 'reset role';
 if not exists(select 1 from public.kuilu_profiles p where p.id=fixture and p.username=meta->>'kuilu_username' and p.role='customer') then raise exception 'atomic profile provisioning failed';end if;
 perform set_config('request.jwt.claim.sub',admin_id::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',admin_id,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 result:=public.kuilu_list_users(username);
 if (result->>'total')::int<>1 or result->'users'->0->>'username'<>username then raise exception 'admin username listing failed';end if;
 if result->'users'->0->>'email' is not null then raise exception 'internal email exposed';end if;
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',fixture::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',fixture,'role','authenticated')::text,true);
 execute 'set local role authenticated';
 denied:=false;
 begin update public.kuilu_profiles set username='evil',role='admin' where id=fixture;exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'customer can edit username/role';end if;
 denied:=false;
 begin insert into public.kuilu_profiles(id,role,username) values(gen_random_uuid(),'admin','evil');exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'customer can provision profile';end if;
 denied:=false;
 begin perform public.kuilu_list_users();exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'customer sees directory';end if;
 execute 'reset role';
 meta:=meta||jsonb_build_object('kuilu_created_by',fixture,'kuilu_username',username||'x');
 denied:=false;
 begin set constraints all deferred; insert into auth.users(id,email,raw_app_meta_data) values(gen_random_uuid(),username||'x@accounts.kuilu.invalid',meta); set constraints all immediate; exception when insufficient_privilege then denied:=true;end;
 if not denied then raise exception 'nonadmin creator bypassed guard';end if;
 execute 'reset role';
end $$;
select 'PASS: 公开注册被拒；原子创建已确认账号及资料；管理员按账号搜索；客户不能升权、改账号或自行建档；内部Auth权限检查；数据回滚' as result;
rollback;
