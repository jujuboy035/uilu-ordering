begin;
do $$
declare owner_id uuid;c uuid:=gen_random_uuid();a uuid:=gen_random_uuid();cn text:='qa-'||gen_random_uuid();jp text:='qa-'||gen_random_uuid();ids uuid[]:=array[gen_random_uuid(),gen_random_uuid(),gen_random_uuid()];d1 date:=(now()at time zone 'Asia/Shanghai')::date+2;d2 date:=d1+1;p jsonb;num1 text;num2 text;num3 text;edited text;denied boolean;i integer;u uuid;role_name text;
begin
 select id into owner_id from public.kuilu_profiles where role='system_admin' order by created_at limit 1;
 for i in 1..2 loop
  u:=case i when 1 then c else a end;role_name:=case i when 1 then 'customer' else 'admin' end;
  insert into auth.users(id,email,raw_app_meta_data)values(u,'qa'||substr(replace(u::text,'-',''),1,20)||'@accounts.kuilu.invalid',jsonb_build_object('kuilu_provisioned',true,'kuilu_username','qa'||substr(replace(u::text,'-',''),1,20),'kuilu_created_by',owner_id,'kuilu_role',role_name));
 end loop;set constraints all immediate;
 perform set_config('request.jwt.claim.sub',c::text,true);execute 'set local role authenticated';
 insert into public.kuilu_addresses(id,country,name,contact,phone,postal,region,street)values(cn,'CN','QA','S','000','','CN','Road'),(jp,'JP','QA','R','000','','JP','Road');
 p:=jsonb_build_object('schemaVersion',3,'cargo',jsonb_build_array(jsonb_build_object('name','Sample','packaging','袋子','qty',1,'unitPrice',1,'currency','USD','photos','[]'::jsonb)),'pickupDate',d1::text,'pickupContact','QA');
 insert into public.kuilu_orders(id,cn_address_id,jp_address_id,payload)values(ids[1],cn,jp,p)returning order_number into num1;
 insert into public.kuilu_orders(id,cn_address_id,jp_address_id,payload)values(ids[2],cn,jp,p)returning order_number into num2;
 insert into public.kuilu_orders(id,cn_address_id,jp_address_id,payload)values(ids[3],cn,jp,p||jsonb_build_object('pickupDate',d2::text))returning order_number into num3;
 if left(num1,8)<>to_char(d1,'YYYYMMDD')or left(num3,8)<>to_char(d2,'YYYYMMDD')or right(num2,4)::integer<>right(num1,4)::integer+1 then raise exception 'pickup-date numbering failed';end if;
 if(select count(*)from public.kuilu_orders where id=any(ids)and payload->>'pickupDate'>=d1::text and payload->>'pickupDate'<=d1::text)<>2 then raise exception 'inclusive pickup date filter failed';end if;
 denied:=false;begin perform kuilu_private.next_pickup_order_number(d1);exception when others then denied:=true;end;if not denied then raise exception 'customer can consume counter';end if;
 execute 'reset role';perform set_config('request.jwt.claim.sub',a::text,true);execute 'set local role authenticated';
 perform public.kuilu_edit_order(ids[1],0,jsonb_build_object('pickupDate',d2::text));
 select order_number into edited from public.kuilu_orders where id=ids[1];
 if left(edited,8)<>to_char(d2,'YYYYMMDD')or right(edited,4)::integer<>right(num3,4)::integer+1 then raise exception 'date edit renumber failed';end if;
 if not exists(select 1 from public.kuilu_orders where id=ids[1]and workflow_history->1->'before'->>'order_number'=num1 and workflow_history->1->'after'->>'order_number'=edited)then raise exception 'number history missing';end if;
 perform public.kuilu_edit_order(ids[1],1,jsonb_build_object('pickupDate',d2::text,'pickupNote','same date'));
 if not exists(select 1 from public.kuilu_orders where id=ids[1]and order_number=edited and payload->>'deliveryDate'=(d2+1)::text)then raise exception 'unchanged date renumbered or delivery wrong';end if;
 execute 'reset role';
end $$;
select 'PASS: pickup-date sequence, same-day increments, separate dates, inclusive filtering, atomic renumber on date edit and number audit' result;
rollback;
