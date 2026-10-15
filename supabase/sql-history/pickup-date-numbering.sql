-- Atomic sequence is scoped to the Chinese pickup date, not submission time.
create function kuilu_private.next_pickup_order_number(p_day date) returns text language plpgsql security definer set search_path='' as $$
declare n integer;
begin
 if p_day is null or not isfinite(p_day) then raise exception '取货日期无效';end if;
 insert into kuilu_private.order_counters(day,last_number) values(p_day,1) on conflict(day)do update set last_number=kuilu_private.order_counters.last_number+1 returning last_number into n;
 return to_char(p_day,'YYYYMMDD')||lpad(n::text,4,'0');
end $$;
revoke all on function kuilu_private.next_pickup_order_number(date)from public,anon,authenticated;
create or replace function kuilu_private.number_order()returns trigger language plpgsql security definer set search_path='' as $$
declare pickup date;
begin
 if auth.uid() is null or new.user_id is distinct from auth.uid() or not exists(select 1 from public.kuilu_profiles where id=auth.uid() and role='customer')then raise exception '仅客户可下单';end if;
 if coalesce(new.payload->>'pickupDate','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception '取货日期无效';end if;
 pickup:=(new.payload->>'pickupDate')::date;
 if pickup<(now()at time zone 'Asia/Shanghai')::date then raise exception '取货日期不能早于今天';end if;
 new.order_number:=kuilu_private.next_pickup_order_number(pickup);
 new.measurements:='[]';new.japan_driver_id:=null;new.courier_id:=null;new.revision:=0;new.package_id:=null;new.package_number:=null;new.deleted_at:=null;new.deleted_by:=null;new.pickup_photos:='[]';
 new.workflow_history:=jsonb_build_array(jsonb_build_object('action','submitted','at',now(),'by',auth.uid(),'order_number',new.order_number));
 return new;
end $$;
create or replace function kuilu_private.edit_order(p_id uuid,p_expected_revision bigint,p_changes jsonb) returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();o public.kuilu_orders%rowtype;payload_out jsonb;snapshot_out jsonb;items jsonb:='[]';item jsonb;original jsonb;section text;k text;v text;limits integer;idx integer:=0;pickup date;next_number text;
begin
 if actor is null or not exists(select 1 from public.kuilu_profiles where id=actor and role in ('admin','system_admin')) then raise exception '仅管理员可修改订单' using errcode='42501';end if;
 select * into o from public.kuilu_orders where id=p_id for update;
 if not found then raise exception '订单不存在';end if;
 if o.deleted_at is not null then raise exception '订单已删除，请先恢复';end if;
 if o.package_id is not null then raise exception '订单已打包，不能修改或单独分配';end if;
 if p_expected_revision is distinct from o.revision then raise exception '订单已被更新，请刷新后再修改';end if;
 if jsonb_typeof(p_changes) is distinct from 'object' or pg_column_size(p_changes)>65536 then raise exception '订单资料格式无效';end if;
 if exists(select 1 from jsonb_object_keys(p_changes) key where key not in ('cargo','cn','jp','pickupDate','pickupContact','pickupNote','deliveryNote')) then raise exception '包含不允许修改的字段';end if;
 payload_out:=o.payload;snapshot_out:=o.address_snapshot;next_number:=o.order_number;
 if p_changes ? 'cargo' then
  if jsonb_typeof(p_changes->'cargo') is distinct from 'array' or jsonb_array_length(p_changes->'cargo')<>jsonb_array_length(o.payload->'cargo') then raise exception '请保留原有货物明细行数';end if;
  for item in select value from jsonb_array_elements(p_changes->'cargo') loop
   original:=o.payload->'cargo'->idx;
   if jsonb_typeof(item) is distinct from 'object' or coalesce(length(trim(item->>'name')),0) not between 1 and 200 or coalesce(item->>'packaging','') not in ('袋子','纸箱') or coalesce(item->>'qty','') !~ '^[1-9][0-9]{0,6}$' or coalesce(item->>'unitPrice','') !~ '^[0-9]+([.][0-9]{1,2})?$' or coalesce(item->>'currency','') not in ('USD','CNY','JPY') then raise exception '货物明细或申报资料无效';end if;
   if (item->>'qty')::numeric>1000000 or (item->>'unitPrice')::numeric<=0 or (item->>'unitPrice')::numeric>999999999999 or coalesce(length(item->>'special'),0)>2000 then raise exception '申报数值或备注超出范围';end if;
   items:=items||jsonb_build_array(original||jsonb_build_object('name',trim(item->>'name'),'packaging',item->>'packaging','qty',(item->>'qty')::integer,'unitPrice',(item->>'unitPrice')::numeric,'currency',item->>'currency','special',coalesce(item->>'special',''),'declaredTotal',round((item->>'qty')::numeric*(item->>'unitPrice')::numeric,2)));
   idx:=idx+1;
  end loop;
  payload_out:=jsonb_set(payload_out,'{cargo}',items);
 end if;
 foreach section in array array['cn','jp'] loop
  if p_changes ? section then
   if jsonb_typeof(p_changes->section) is distinct from 'object' then raise exception '地址格式无效';end if;
   foreach k in array array['name','contact','phone','region','street'] loop
    v:=trim(p_changes->section->>k);limits:=case k when 'name' then 150 when 'contact' then 150 when 'phone' then 50 when 'region' then 300 else 500 end;
    if v is null or length(v) not between 1 and limits then raise exception '请填写完整有效的公司、联系人和地址';end if;
    snapshot_out:=jsonb_set(snapshot_out,array[section,k],to_jsonb(v));
   end loop;
  end if;
 end loop;
 foreach k in array array['pickupContact','pickupNote','deliveryNote'] loop
  if p_changes ? k then
   v:=p_changes->>k;
   if v is null or length(v)>2000 or (k='pickupContact' and length(trim(v))=0) then raise exception '联系人或备注无效';end if;
   payload_out:=jsonb_set(payload_out,array[k],to_jsonb(v));
  end if;
 end loop;
 if p_changes ? 'pickupDate' then
  if coalesce(p_changes->>'pickupDate','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then raise exception '取货日期无效';end if;
  pickup:=(p_changes->>'pickupDate')::date;
  if pickup::text is distinct from o.payload->>'pickupDate' then next_number:=kuilu_private.next_pickup_order_number(pickup);end if;
  payload_out:=payload_out||jsonb_build_object('pickupDate',pickup::text,'deliveryDate',(pickup+1)::text,'deliveryTime','12:00前');
 end if;
 update public.kuilu_orders set order_number=next_number,payload=payload_out,address_snapshot=snapshot_out,revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action','edit','at',now(),'by',actor,'before',jsonb_build_object('order_number',o.order_number,'payload',o.payload,'addresses',o.address_snapshot),'after',jsonb_build_object('order_number',next_number,'payload',payload_out,'addresses',snapshot_out))) where id=p_id;
end $$;
notify pgrst,'reload schema';
