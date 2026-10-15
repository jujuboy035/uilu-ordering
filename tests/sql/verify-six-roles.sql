begin;
do $$
declare owner_id uuid; ids uuid[]:=array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];roles text[]:=array['customer','admin','china_driver','japan_driver','courier','china_driver'];u uuid;i integer;denied boolean;cn text:='qa-'||gen_random_uuid();jp text:='qa-'||gen_random_uuid();o uuid:=gen_random_uuid();number_before text;changes jsonb;m jsonb:='[{"weight":1,"length":20,"width":10,"height":5}]';
begin
 select id into owner_id from public.kuilu_profiles where role='system_admin' order by created_at limit 1;
 if owner_id is null then raise exception 'no system administrator';end if;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);execute 'set local role authenticated';
 denied:=false;begin perform public.kuilu_change_user_role(owner_id,'admin');exception when others then denied:=true;end;
 if (select count(*) from public.kuilu_profiles where role='system_admin')=0 then raise exception 'last system administrator lost';end if;
 execute 'reset role';
 for i in 1..6 loop
  u:=ids[i];insert into auth.users(id,email,raw_app_meta_data)values(u,'qa'||replace(u::text,'-','')||'@accounts.kuilu.invalid',jsonb_build_object('kuilu_provisioned',true,'kuilu_username','qa'||substr(replace(u::text,'-',''),1,20),'kuilu_created_by',owner_id,'kuilu_role',roles[i]));
 end loop;
 -- The alias must match its provisioned username exactly.
 update auth.users set email=(raw_app_meta_data->>'kuilu_username')||'@accounts.kuilu.invalid' where id=any(ids);
 set constraints all immediate;
 perform set_config('request.jwt.claim.sub',ids[1]::text,true);execute 'set local role authenticated';
 insert into public.kuilu_addresses(id,country,name,contact,phone,postal,region,street)values(cn,'CN','Test CN','Sender','000','','China','Road'),(jp,'JP','Test JP','Receiver','000','','Tokyo','Road');
 insert into public.kuilu_orders(id,cn_address_id,jp_address_id,japan_driver_id,courier_id,revision,payload)values(o,cn,jp,ids[4],ids[5],99,jsonb_build_object('schemaVersion',3,'cargo',jsonb_build_array(jsonb_build_object('name','Sample','packaging','袋子','qty',2,'unitPrice',1,'currency','USD','photos','[]'::jsonb)),'pickupDate','2099-01-01','pickupContact','Sender'))returning order_number into number_before;
 if not exists(select 1 from public.kuilu_orders where id=o and japan_driver_id is null and courier_id is null and revision=0)then raise exception 'forged assignment accepted';end if;
 denied:=false;begin perform public.kuilu_change_user_role(ids[1],'system_admin');exception when others then denied:=true;end;if not denied then raise exception 'customer escalated';end if;
 denied:=false;begin perform public.kuilu_edit_order(o,0,'{"pickupNote":"forged"}');exception when others then denied:=true;end;if not denied then raise exception 'customer edited order';end if;
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',ids[2]::text,true);execute 'set local role authenticated';
 perform public.kuilu_list_users();
 if not exists(select 1 from public.kuilu_orders where id=o and japan_driver_id is null and courier_id is null and revision=0)then raise exception 'forged assignment accepted';end if;
 denied:=false;begin perform public.kuilu_change_user_role(ids[1],'admin');exception when others then denied:=true;end;if not denied then raise exception 'admin changed permissions';end if;
 changes:='{"cargo":[{"name":"Edited","packaging":"袋子","qty":3,"unitPrice":"4.77","currency":"USD"}],"jp":{"name":"Edited company","contact":"R","phone":"001","region":"Tokyo","street":"New road"},"pickupNote":"Updated"}';
 perform public.kuilu_edit_order(o,0,changes);
 if not exists(select 1 from public.kuilu_orders where id=o and payload->'cargo'->0->>'declaredTotal'='14.31' and order_number=number_before and revision=1 and workflow_history->1->>'action'='edit')then raise exception 'edit totals/history/version failed';end if;
 denied:=false;begin perform public.kuilu_edit_order(o,0,changes);exception when others then denied:=true;end;if not denied then raise exception 'stale edit accepted';end if;
 denied:=false;begin perform public.kuilu_edit_order(o,1,'{"user_id":"forged"}');exception when others then denied:=true;end;if not denied then raise exception 'ownership edit accepted';end if;
 denied:=false;begin perform public.kuilu_assign_staff(o,'japan',ids[3]);exception when others then denied:=true;end;if not denied then raise exception 'wrong role assigned';end if;
 perform public.kuilu_assign_staff(o,'japan',ids[4]);perform public.kuilu_assign_staff(o,'courier',ids[5]);perform public.kuilu_order_action(o,'assign',ids[3]);
 execute 'reset role';
 for i in 3..6 loop
  perform set_config('request.jwt.claim.sub',ids[i]::text,true);execute 'set local role authenticated';
  if i=6 then if exists(select 1 from public.kuilu_orders where id=o)then raise exception 'unassigned driver read order';end if;
  else if not exists(select 1 from public.kuilu_orders where id=o)then raise exception 'assigned worker cannot read order';end if;end if;
  denied:=false;begin perform public.kuilu_edit_order(o,4,changes);exception when others then denied:=true;end;if not denied then raise exception 'worker edited order';end if;
  denied:=false;begin perform public.kuilu_list_users();exception when others then denied:=true;end;if not denied then raise exception 'worker listed accounts';end if;
  if i=3 then perform public.kuilu_order_action(o,'pickup',null,m);end if;
  execute 'reset role';
 end loop;
 perform set_config('request.jwt.claim.sub',owner_id::text,true);execute 'set local role authenticated';
 perform public.kuilu_change_user_role(ids[5],'system_admin');perform public.kuilu_change_user_role(ids[5],'courier');
 execute 'reset role';
 if not exists(select 1 from kuilu_private.role_history where actor=owner_id and target=ids[5])then raise exception 'missing role audit';end if;
 denied:=false;begin insert into auth.users(id,email,raw_app_meta_data)values(gen_random_uuid(),'qaforged@accounts.kuilu.invalid',jsonb_build_object('kuilu_provisioned',true,'kuilu_username','qaforged','kuilu_created_by',ids[2],'kuilu_role','system_admin'));exception when others then denied:=true;end;if not denied then raise exception 'admin created system admin via metadata';end if;
end $$;
select 'PASS: six-role account boundaries, last-system-admin protection, order editing/audit/totals/version, role changes, stage assignment and worker isolation' result;
rollback;
