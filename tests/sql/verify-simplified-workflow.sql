begin;
do $$
declare a uuid; c uuid:=gen_random_uuid(); d uuid:=gen_random_uuid(); other_driver uuid:=gen_random_uuid(); w uuid:=gen_random_uuid(); ids uuid[]; roles text[]:=array['customer','driver','driver','china']; cn text:='qa-'||gen_random_uuid(); jp text:='qa-'||gen_random_uuid(); o uuid:=gen_random_uuid(); o2 uuid:=gen_random_uuid(); num1 text; num2 text; denied boolean; i integer; u uuid; payload jsonb; m jsonb:='[{"weight":5.2,"length":30,"width":20,"height":10}]';
begin
 select id into a from public.kuilu_profiles where role='admin' limit 1;
 ids:=array[c,d,other_driver,w];
 for i in 1..4 loop
  u:=ids[i];
  insert into auth.users(id,email,raw_app_meta_data) values(u,'qa'||substr(replace(u::text,'-',''),1,20)||'@accounts.kuilu.invalid',jsonb_build_object('kuilu_provisioned',true,'kuilu_username','qa'||substr(replace(u::text,'-',''),1,20),'kuilu_created_by',a,'kuilu_role',roles[i]));
 end loop;
 set constraints all immediate;
 perform set_config('request.jwt.claim.sub',c::text,true);
 execute 'set local role authenticated';
 insert into public.kuilu_addresses(id,country,name,contact,phone,postal,region,street) values(cn,'CN','QA CN','sender','000','','CN','street'),(jp,'JP','QA JP','recipient','000','','JP','street');
 payload:=jsonb_build_object('schemaVersion',3,'cargo',jsonb_build_array(jsonb_build_object('name','测试品','packaging','纸箱','qty',3,'unitPrice','12.34','currency','USD','declaredTotal',0,'photos','[]'::jsonb)),'pickupDate','2099-01-01','pickupContact','QA');
 insert into public.kuilu_orders(id,cn_address_id,jp_address_id,payload,order_number,measurements) values(o,cn,jp,payload,'forged',m) returning order_number into num1;
 insert into public.kuilu_orders(id,cn_address_id,jp_address_id,payload) values(o2,cn,jp,payload) returning order_number into num2;
 if num1!~'^[0-9]{12}$' or left(num1,8)<>to_char(now() at time zone 'Asia/Shanghai','YYYYMMDD') or right(num2,4)::int<>right(num1,4)::int+1 then raise exception 'numbering failed'; end if;
 if not exists(select 1 from public.kuilu_orders where id=o and kuilu_orders.payload->'cargo'->0->>'declaredTotal'='37.02' and measurements='[]') then raise exception 'server totals or measurement reset failed'; end if;
 denied:=false;begin perform public.kuilu_order_action(o,'receive',null,m);exception when others then denied:=true;end;if not denied then raise exception 'customer action allowed';end if;
 insert into public.kuilu_product_presets(name,name_en,packaging,unit_price,currency) values('QA','QA','纸箱',12.34,'CNY');
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',w::text,true);execute 'set local role authenticated';
 if jsonb_array_length(public.kuilu_list_drivers())<2 then raise exception 'driver list failed';end if;
 perform public.kuilu_order_action(o,'assign',d);
 perform public.kuilu_order_action(o2,'receive',null,m);
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',other_driver::text,true);execute 'set local role authenticated';
 if exists(select 1 from public.kuilu_orders where id=o) then raise exception 'other driver can read order';end if;
 if exists(select 1 from public.kuilu_product_presets where user_id=c) then raise exception 'preset leak';end if;
 denied:=false;begin perform public.kuilu_order_action(o,'pickup',null,m);exception when others then denied:=true;end;if not denied then raise exception 'other driver allowed';end if;
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',d::text,true);execute 'set local role authenticated';
 denied:=false;begin perform public.kuilu_order_action(o,'pickup',null,'[{"weight":0}]');exception when others then denied:=true;end;if not denied then raise exception 'bad measurement allowed';end if;
 perform public.kuilu_order_action(o,'pickup',null,m);
 denied:=false;begin perform public.kuilu_order_action(o,'pickup',null,m);exception when others then denied:=true;end;if not denied then raise exception 'duplicate pickup allowed';end if;
 denied:=false;begin perform public.kuilu_order_action(o,'receive',null,m);exception when others then denied:=true;end;if not denied then raise exception 'driver warehouse allowed';end if;
 execute 'reset role';
 perform set_config('request.jwt.claim.sub',w::text,true);execute 'set local role authenticated';
 perform public.kuilu_order_action(o,'receive',null,'[{"weight":5.3,"length":31,"width":21,"height":11}]');
 if not exists(select 1 from public.kuilu_orders where id=o and status='cn_warehouse' and jsonb_array_length(workflow_history)=4 and measurements->0->>'weight'='5.3') then raise exception 'warehouse or history failed';end if;
 denied:=false;begin perform public.kuilu_order_action(o,'assign',d);exception when others then denied:=true;end;if not denied then raise exception 'terminal reassign allowed';end if;
 execute 'reset role';
end $$;
select 'PASS: daily numbers, trusted totals, preset isolation, staff assignment, assigned-driver pickup, direct warehouse receipt, measurements, history and forbidden transitions' result;
rollback;

