create table public.kuilu_packages(
 id uuid primary key default gen_random_uuid(),package_number text not null unique,
 label text not null default '' check(length(label)<=200),status text not null default 'packed' check(status in ('packed','assigned','cancelled')),
 courier_id uuid references public.kuilu_profiles(id),created_by uuid not null references public.kuilu_profiles(id),created_at timestamptz not null default now(),history jsonb not null default '[]'
);
alter table public.kuilu_packages enable row level security;
revoke all on public.kuilu_packages from public,anon,authenticated;
grant select on public.kuilu_packages to authenticated;
create policy kuilu_package_read on public.kuilu_packages for select to authenticated using((select public.kuilu_role()) in ('admin','system_admin') or ((select public.kuilu_role())='courier' and courier_id=(select auth.uid()) and status='assigned'));
create index kuilu_packages_courier on public.kuilu_packages(courier_id,created_at desc);
create table kuilu_private.package_counters(day date primary key,last_number integer not null check(last_number between 1 and 9999));
alter table kuilu_private.package_counters enable row level security;
revoke all on kuilu_private.package_counters from public,anon,authenticated;
alter table public.kuilu_orders add column package_id uuid references public.kuilu_packages(id),add column package_number text,add column deleted_at timestamptz,add column deleted_by uuid references public.kuilu_profiles(id),add column pickup_photos jsonb not null default '[]';
create index kuilu_orders_package on public.kuilu_orders(package_id);

drop policy kuilu_order_read on public.kuilu_orders;
create policy kuilu_order_read on public.kuilu_orders for select to authenticated using(
 (select public.kuilu_role()) in ('admin','system_admin') or (deleted_at is null and (
 (user_id=(select auth.uid()) and (select public.kuilu_role())='customer')
 or ((select public.kuilu_role())='china_driver' and driver_id=(select auth.uid()))
 or ((select public.kuilu_role())='japan_driver' and japan_driver_id=(select auth.uid()))
 or ((select public.kuilu_role())='courier' and courier_id=(select auth.uid()) and package_id is not null))));

create function kuilu_private.remove_order(p_id uuid,p_restore boolean default false) returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();o public.kuilu_orders%rowtype;
begin
 if actor is null or not exists(select 1 from public.kuilu_profiles where id=actor and role in ('admin','system_admin')) then raise exception '仅管理员可删除或恢复订单' using errcode='42501';end if;
 select * into o from public.kuilu_orders where id=p_id for update;if not found then raise exception '订单不存在';end if;
 if o.package_id is not null then raise exception '订单已装入包裹，请先撤销打包';end if;
 if (p_restore and o.deleted_at is null) or (not p_restore and o.deleted_at is not null) then raise exception '订单删除状态已变化，请刷新';end if;
 if p_restore is null then raise exception '操作无效';end if;
 update public.kuilu_orders set deleted_at=case when p_restore then null else now() end,deleted_by=case when p_restore then null else actor end,revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action',case when p_restore then 'restore' else 'delete' end,'at',now(),'by',actor)) where id=p_id;
end $$;
revoke all on function kuilu_private.remove_order(uuid,boolean) from public,anon;
grant execute on function kuilu_private.remove_order(uuid,boolean) to authenticated;
create function public.kuilu_remove_order(p_id uuid,p_restore boolean default false) returns void language sql security invoker set search_path='' as $$select kuilu_private.remove_order(p_id,p_restore)$$;
revoke all on function public.kuilu_remove_order(uuid,boolean) from public,anon;grant execute on function public.kuilu_remove_order(uuid,boolean) to authenticated;

create function kuilu_private.make_package(p_orders uuid[],p_label text default '') returns uuid language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();pid uuid:=gen_random_uuid();o public.kuilu_orders%rowtype;n integer;d date:=(now() at time zone 'Asia/Shanghai')::date;found_count integer:=0;
begin
 if actor is null or not exists(select 1 from public.kuilu_profiles where id=actor and role in ('admin','system_admin')) then raise exception '仅管理员可打包' using errcode='42501';end if;
 if p_orders is null or cardinality(p_orders) not between 1 and 100 or cardinality(p_orders)<>(select count(distinct x) from unnest(p_orders)x) or coalesce(length(p_label),0)>200 then raise exception '请选择1至100个不同的入库订单';end if;
 for o in select * from public.kuilu_orders where id=any(p_orders) order by id for update loop
  found_count:=found_count+1;
  if o.deleted_at is not null or o.package_id is not null or o.status<>'cn_warehouse' then raise exception '只能打包未删除、未打包的仓库已收货订单';end if;
 end loop;
 if found_count<>cardinality(p_orders) then raise exception '部分订单不存在';end if;
 insert into kuilu_private.package_counters(day,last_number) values(d,1) on conflict(day) do update set last_number=kuilu_private.package_counters.last_number+1 returning last_number into n;
 insert into public.kuilu_packages(id,package_number,label,created_by,history)values(pid,'PKG'||to_char(d,'YYYYMMDD')||lpad(n::text,4,'0'),coalesce(p_label,''),actor,jsonb_build_array(jsonb_build_object('action','packed','at',now(),'by',actor,'orders',p_orders)));
 update public.kuilu_orders set package_id=pid,package_number='PKG'||to_char(d,'YYYYMMDD')||lpad(n::text,4,'0'),courier_id=null,revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action','packed','at',now(),'by',actor,'package_id',pid))where id=any(p_orders);
 return pid;
end $$;
revoke all on function kuilu_private.make_package(uuid[],text) from public,anon;grant execute on function kuilu_private.make_package(uuid[],text) to authenticated;
create function public.kuilu_make_package(p_orders uuid[],p_label text default '')returns uuid language sql security invoker set search_path='' as $$select kuilu_private.make_package(p_orders,p_label)$$;
revoke all on function public.kuilu_make_package(uuid[],text) from public,anon;grant execute on function public.kuilu_make_package(uuid[],text) to authenticated;

create function kuilu_private.package_action(p_id uuid,p_action text,p_courier uuid default null)returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();p public.kuilu_packages%rowtype;
begin
 if actor is null or not exists(select 1 from public.kuilu_profiles where id=actor and role in ('admin','system_admin')) then raise exception '仅管理员可管理包裹' using errcode='42501';end if;
 select * into p from public.kuilu_packages where id=p_id for update;if not found then raise exception '包裹不存在';end if;
 if p.status='cancelled' then raise exception '包裹已撤销';end if;
 perform id from public.kuilu_orders where package_id=p_id order by id for update;
 if p_action='assign' then
  if p_courier is null or not exists(select 1 from public.kuilu_profiles where id=p_courier and role='courier')then raise exception '请选择有效的跨境手提员';end if;
  update public.kuilu_packages set courier_id=p_courier,status='assigned',history=history||jsonb_build_array(jsonb_build_object('action','assign','at',now(),'by',actor,'courier',p_courier))where id=p_id;
  update public.kuilu_orders set courier_id=p_courier,revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action','assign_courier','at',now(),'by',actor,'package_id',p_id,'assigned_user',p_courier))where package_id=p_id;
 elsif p_action='unpack' then
  if p.status<>'packed' then raise exception '已分配手提员的包裹不能撤销打包';end if;
  update public.kuilu_packages set status='cancelled',history=history||jsonb_build_array(jsonb_build_object('action','unpack','at',now(),'by',actor))where id=p_id;
  update public.kuilu_orders set package_id=null,package_number=null,courier_id=null,revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action','unpacked','at',now(),'by',actor,'package_id',p_id))where package_id=p_id;
 else raise exception '包裹操作无效';end if;
end $$;
revoke all on function kuilu_private.package_action(uuid,text,uuid) from public,anon;grant execute on function kuilu_private.package_action(uuid,text,uuid)to authenticated;
create function public.kuilu_package_action(p_id uuid,p_action text,p_courier uuid default null)returns void language sql security invoker set search_path='' as $$select kuilu_private.package_action(p_id,p_action,p_courier)$$;
revoke all on function public.kuilu_package_action(uuid,text,uuid)from public,anon;grant execute on function public.kuilu_package_action(uuid,text,uuid)to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('kuilu-pickup','kuilu-pickup',false,2097152,array['image/jpeg','image/png','image/webp']);
create policy kuilu_pickup_upload on storage.objects for insert to authenticated with check(bucket_id='kuilu-pickup' and (select public.kuilu_role())='china_driver' and (storage.foldername(name))[1]='pickup' and (storage.foldername(name))[3]=(select auth.uid())::text and name !~ '(^|/)\.\.(/|$)' and exists(select 1 from public.kuilu_orders o where o.id::text=(storage.foldername(name))[2] and o.driver_id=(select auth.uid()) and o.status='pickup' and o.deleted_at is null and o.package_id is null));
create policy kuilu_pickup_read on storage.objects for select to authenticated using(bucket_id='kuilu-pickup' and exists(select 1 from public.kuilu_orders o where o.id::text=(storage.foldername(storage.objects.name))[2] and (
 (select public.kuilu_role()) in ('admin','system_admin') or (o.deleted_at is null and (
 ((select public.kuilu_role())='customer' and o.user_id=(select auth.uid()))
 or ((select public.kuilu_role())='china_driver' and o.driver_id=(select auth.uid()))
 or ((select public.kuilu_role())='japan_driver' and o.japan_driver_id=(select auth.uid()))
 or ((select public.kuilu_role())='courier' and o.courier_id=(select auth.uid()) and o.package_id is not null))))));
create function kuilu_private.can_remove_pickup_photo(p_path text)returns boolean language sql stable security definer set search_path='' as $$select auth.uid() is not null and split_part(p_path,'/',3)=auth.uid()::text and not exists(select 1 from public.kuilu_orders where pickup_photos ? p_path)$$;
revoke all on function kuilu_private.can_remove_pickup_photo(text)from public,anon;grant execute on function kuilu_private.can_remove_pickup_photo(text)to authenticated;
create policy kuilu_pickup_cleanup on storage.objects for delete to authenticated using(bucket_id='kuilu-pickup' and kuilu_private.can_remove_pickup_photo(name));

create function kuilu_private.pickup_order(p_id uuid,p_measurements jsonb,p_photos jsonb)returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();o public.kuilu_orders%rowtype;m jsonb;k text;path text;
begin
 if actor is null or not exists(select 1 from public.kuilu_profiles where id=actor and role='china_driver')then raise exception '仅中国司机可确认取货' using errcode='42501';end if;
 select * into o from public.kuilu_orders where id=p_id for update;
 if not found or o.driver_id is distinct from actor or o.status<>'pickup' or o.deleted_at is not null or o.package_id is not null then raise exception '仅指定司机可确认待取货订单';end if;
 if jsonb_typeof(p_measurements) is distinct from 'array' or jsonb_array_length(p_measurements)<>jsonb_array_length(o.payload->'cargo')then raise exception '请填写每项货物的实重和长宽高';end if;
 for m in select value from jsonb_array_elements(p_measurements)loop
  foreach k in array array['weight','length','width','height']loop
   if coalesce(m->>k,'') !~ '^[0-9]+([.][0-9]{1,3})?$' then raise exception '实重和长宽高须为正数，最多三位小数';end if;
   if (m->>k)::numeric<=0 or (m->>k)::numeric>1000000 then raise exception '实重和长宽高超出范围';end if;
  end loop;
 end loop;
 if jsonb_typeof(p_photos) is distinct from 'array' or jsonb_array_length(p_photos)not between 1 and 6 then raise exception '取货至少上传1张照片，最多6张';end if;
 if exists(select 1 from jsonb_array_elements(p_photos)v where jsonb_typeof(v) is distinct from 'string')then raise exception '照片资料无效';end if;
 if (select count(distinct v)from jsonb_array_elements_text(p_photos)v)<>jsonb_array_length(p_photos)then raise exception '照片不能重复';end if;
 for path in select jsonb_array_elements_text(p_photos)loop
  if path not like 'pickup/'||p_id::text||'/'||actor::text||'/%' or path ~ '(^|/)\.\.(/|$)' or not exists(select 1 from storage.objects where bucket_id='kuilu-pickup' and name=path)then raise exception '取货照片不存在或无权使用';end if;
 end loop;
 update public.kuilu_orders set status='picked_up',measurements=p_measurements,pickup_photos=p_photos,revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action','pickup','at',now(),'by',actor,'measurements',p_measurements,'photos',p_photos))where id=p_id;
end $$;
revoke all on function kuilu_private.pickup_order(uuid,jsonb,jsonb)from public,anon;grant execute on function kuilu_private.pickup_order(uuid,jsonb,jsonb)to authenticated;
create function public.kuilu_pickup_order(p_id uuid,p_measurements jsonb,p_photos jsonb)returns void language sql security invoker set search_path='' as $$select kuilu_private.pickup_order(p_id,p_measurements,p_photos)$$;
revoke all on function public.kuilu_pickup_order(uuid,jsonb,jsonb)from public,anon;grant execute on function public.kuilu_pickup_order(uuid,jsonb,jsonb)to authenticated;

create or replace function kuilu_private.order_action(p_id uuid,p_action text,p_driver uuid default null,p_measurements jsonb default '[]') returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); actor_role text; o public.kuilu_orders%rowtype; m jsonb; k text; next_status text;
begin
 select role into actor_role from public.kuilu_profiles where id=actor;
 if actor is null or actor_role is null or actor_role not in ('admin','system_admin','china_driver') then raise exception '无权操作此订单'; end if;
 select * into o from public.kuilu_orders where id=p_id for update;
 if not found then raise exception '订单不存在'; end if;
 if o.deleted_at is not null then raise exception '订单已删除，请先恢复';end if;
 if o.package_id is not null then raise exception '订单已打包，不能修改或单独分配';end if;
 if p_action='pickup' then raise exception '取货必须使用带照片的确认流程';end if;
 if p_action='assign' then
  if actor_role not in ('admin','system_admin') or o.status not in ('pending_review','approved','pickup') then raise exception '当前状态不能分配司机'; end if;
  if p_driver is null or not exists(select 1 from public.kuilu_profiles where id=p_driver and role='china_driver') then raise exception '请选择有效司机'; end if;
  next_status:='pickup';
 elsif p_action in ('pickup','receive') then
  if p_action='pickup' then
   if actor_role<>'china_driver' or o.driver_id is distinct from actor or o.status<>'pickup' then raise exception '仅指定司机可确认取货'; end if;
   next_status:='picked_up';
  else
   if actor_role not in ('admin','system_admin') or o.status not in ('pending_review','approved','pickup','picked_up') then raise exception '当前状态不能入库'; end if;
   next_status:='cn_warehouse';
  end if;
  if jsonb_typeof(p_measurements) is distinct from 'array' then raise exception '请填写实重和长宽高'; end if;
  if jsonb_array_length(p_measurements)<>jsonb_array_length(o.payload->'cargo') then raise exception '请填写每项货物的实重和长宽高'; end if;
  for m in select value from jsonb_array_elements(p_measurements) loop
   foreach k in array array['weight','length','width','height'] loop
    if coalesce(m->>k,'') !~ '^[0-9]+([.][0-9]{1,3})?$' then raise exception '实重和长宽高须为正数，最多三位小数'; end if;
    if (m->>k)::numeric<=0 or (m->>k)::numeric>1000000 then raise exception '实重和长宽高超出范围'; end if;
   end loop;
  end loop;
 else raise exception '未知操作'; end if;
 update public.kuilu_orders set status=next_status,driver_id=case when p_action='assign' then p_driver else driver_id end,
 measurements=case when p_action='assign' then measurements else p_measurements end,
 revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action',p_action,'at',now(),'by',actor,'driver',case when p_action='assign' then p_driver else o.driver_id end,'measurements',case when p_action='assign' then '[]'::jsonb else p_measurements end)) where id=p_id;
end $$;

create or replace function kuilu_private.edit_order(p_id uuid,p_expected_revision bigint,p_changes jsonb) returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();o public.kuilu_orders%rowtype;payload_out jsonb;snapshot_out jsonb;items jsonb:='[]';item jsonb;original jsonb;section text;k text;v text;limits integer;idx integer:=0;pickup date;
begin
 if actor is null or not exists(select 1 from public.kuilu_profiles where id=actor and role in ('admin','system_admin')) then raise exception '仅管理员可修改订单' using errcode='42501';end if;
 select * into o from public.kuilu_orders where id=p_id for update;
 if not found then raise exception '订单不存在';end if;
 if o.deleted_at is not null then raise exception '订单已删除，请先恢复';end if;
 if o.package_id is not null then raise exception '订单已打包，不能修改或单独分配';end if;
 if p_expected_revision is distinct from o.revision then raise exception '订单已被更新，请刷新后再修改';end if;
 if jsonb_typeof(p_changes) is distinct from 'object' or pg_column_size(p_changes)>65536 then raise exception '订单资料格式无效';end if;
 if exists(select 1 from jsonb_object_keys(p_changes) key where key not in ('cargo','cn','jp','pickupDate','pickupContact','pickupNote','deliveryNote')) then raise exception '包含不允许修改的字段';end if;
 payload_out:=o.payload;snapshot_out:=o.address_snapshot;
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
  payload_out:=payload_out||jsonb_build_object('pickupDate',pickup::text,'deliveryDate',(pickup+1)::text,'deliveryTime','12:00前');
 end if;
 update public.kuilu_orders set payload=payload_out,address_snapshot=snapshot_out,revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action','edit','at',now(),'by',actor,'before',jsonb_build_object('payload',o.payload,'addresses',o.address_snapshot),'after',jsonb_build_object('payload',payload_out,'addresses',snapshot_out))) where id=p_id;
end $$;

create or replace function kuilu_private.assign_staff(p_id uuid,p_kind text,p_user uuid) returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid();required_role text;o public.kuilu_orders%rowtype;
begin
 if actor is null or not exists(select 1 from public.kuilu_profiles where id=actor and role in ('admin','system_admin')) then raise exception '仅管理员可分配工作人员' using errcode='42501';end if;
 if p_kind='courier' then raise exception '请在包裹工作台分配跨境手提员';end if;
 required_role:=case p_kind when 'japan' then 'japan_driver' when 'courier' then 'courier' else null end;
 if required_role is null or p_user is null or not exists(select 1 from public.kuilu_profiles where id=p_user and role=required_role) then raise exception '请选择对应角色的工作人员';end if;
 select * into o from public.kuilu_orders where id=p_id for update;
 if not found then raise exception '订单不存在';end if;
 if o.deleted_at is not null then raise exception '订单已删除，请先恢复';end if;
 if o.package_id is not null then raise exception '订单已打包，不能修改或单独分配';end if;
 if o.status in ('delivered','cancelled') then raise exception '已结束订单不能分配工作人员';end if;
 update public.kuilu_orders set japan_driver_id=case when p_kind='japan' then p_user else japan_driver_id end,courier_id=case when p_kind='courier' then p_user else courier_id end,revision=revision+1,workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action','assign_'||p_kind,'at',now(),'by',actor,'assigned_user',p_user)) where id=p_id;
end $$;

create or replace function kuilu_private.number_order() returns trigger language plpgsql security definer set search_path='' as $$
declare n integer; d date:=(now() at time zone 'Asia/Shanghai')::date;
begin
 if auth.uid() is null or new.user_id is distinct from auth.uid() or not exists(select 1 from public.kuilu_profiles where id=auth.uid() and role='customer') then raise exception '仅客户可下单'; end if;
 insert into kuilu_private.order_counters(day,last_number) values(d,1) on conflict(day) do update set last_number=kuilu_private.order_counters.last_number+1 returning last_number into n;
 new.order_number:=to_char(d,'YYYYMMDD')||lpad(n::text,4,'0');
 new.measurements:='[]';new.japan_driver_id:=null;new.courier_id:=null;new.revision:=0;new.package_id:=null;new.package_number:=null;new.deleted_at:=null;new.deleted_by:=null;new.pickup_photos:='[]';
 new.workflow_history:=jsonb_build_array(jsonb_build_object('action','submitted','at',now(),'by',auth.uid()));
 return new;
end $$;
revoke all on function kuilu_private.number_order() from public,anon,authenticated;

notify pgrst,'reload schema';
