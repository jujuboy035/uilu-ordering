-- Atomic daily numbering; historical order numbers stay unchanged.
create table kuilu_private.order_counters(day date primary key, last_number integer not null check(last_number between 1 and 9999));
alter table kuilu_private.order_counters enable row level security;
revoke all on kuilu_private.order_counters from public,anon,authenticated;
alter table public.kuilu_orders add column measurements jsonb not null default '[]', add column workflow_history jsonb not null default '[]';
alter table public.kuilu_orders drop constraint kuilu_orders_status_check;
alter table public.kuilu_orders add constraint kuilu_orders_status_check check(status in ('pending_review','approved','pickup','picked_up','cn_warehouse','in_transit','arrived','delivering','delivered','cancelled'));
create function kuilu_private.number_order() returns trigger language plpgsql security definer set search_path='' as $$
declare n integer; d date:=(now() at time zone 'Asia/Shanghai')::date;
begin
 if auth.uid() is null or new.user_id is distinct from auth.uid() or not exists(select 1 from public.kuilu_profiles where id=auth.uid() and role='customer') then raise exception '仅客户可下单'; end if;
 insert into kuilu_private.order_counters(day,last_number) values(d,1) on conflict(day) do update set last_number=kuilu_private.order_counters.last_number+1 returning last_number into n;
 new.order_number:=to_char(d,'YYYYMMDD')||lpad(n::text,4,'0');
 new.measurements:='[]';
 new.workflow_history:=jsonb_build_array(jsonb_build_object('action','submitted','at',now(),'by',auth.uid()));
 return new;
end $$;
revoke all on function kuilu_private.number_order() from public,anon,authenticated;
create trigger kuilu_order_number before insert on public.kuilu_orders for each row execute function kuilu_private.number_order();

create table public.kuilu_product_presets(
 id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references public.kuilu_profiles(id),
 name text not null check(length(trim(name)) between 1 and 200), name_en text not null check(length(trim(name_en)) between 1 and 200),
 packaging text not null check(length(trim(packaging)) between 1 and 80), unit_price numeric(14,2) not null check(unit_price>0),
 currency text not null check(currency in ('CNY','JPY','USD')), unique(user_id,name,name_en)
);
alter table public.kuilu_product_presets enable row level security;
revoke all on public.kuilu_product_presets from public,anon,authenticated;
grant select,insert,update,delete on public.kuilu_product_presets to authenticated;
create policy preset_owner on public.kuilu_product_presets for all to authenticated using(user_id=(select auth.uid())) with check(user_id=(select auth.uid()));

-- Private, narrowly scoped RPC implementation: row lock and explicit role/assignment checks.
create function kuilu_private.order_action(p_id uuid,p_action text,p_driver uuid default null,p_measurements jsonb default '[]') returns void language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); actor_role text; o public.kuilu_orders%rowtype; m jsonb; k text; next_status text;
begin
 select role into actor_role from public.kuilu_profiles where id=actor;
 if actor is null or actor_role is null or actor_role not in ('admin','china','driver') then raise exception '无权操作此订单'; end if;
 select * into o from public.kuilu_orders where id=p_id for update;
 if not found then raise exception '订单不存在'; end if;
 if p_action='assign' then
  if actor_role not in ('admin','china') or o.status not in ('pending_review','approved','pickup') then raise exception '当前状态不能分配司机'; end if;
  if p_driver is null or not exists(select 1 from public.kuilu_profiles where id=p_driver and role='driver') then raise exception '请选择有效司机'; end if;
  next_status:='pickup';
 elsif p_action in ('pickup','receive') then
  if p_action='pickup' then
   if actor_role<>'driver' or o.driver_id is distinct from actor or o.status<>'pickup' then raise exception '仅指定司机可确认取货'; end if;
   next_status:='picked_up';
  else
   if actor_role not in ('admin','china') or o.status not in ('pending_review','approved','pickup','picked_up') then raise exception '当前状态不能入库'; end if;
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
 workflow_history=workflow_history||jsonb_build_array(jsonb_build_object('action',p_action,'at',now(),'by',actor,'driver',case when p_action='assign' then p_driver else o.driver_id end,'measurements',case when p_action='assign' then '[]'::jsonb else p_measurements end)) where id=p_id;
end $$;
revoke all on function kuilu_private.order_action(uuid,text,uuid,jsonb) from public,anon;
grant usage on schema kuilu_private to authenticated;
grant execute on function kuilu_private.order_action(uuid,text,uuid,jsonb) to authenticated;
create function public.kuilu_order_action(p_id uuid,p_action text,p_driver uuid default null,p_measurements jsonb default '[]') returns void language sql security invoker set search_path='' as $$ select kuilu_private.order_action(p_id,p_action,p_driver,p_measurements) $$;
revoke all on function public.kuilu_order_action(uuid,text,uuid,jsonb) from public,anon;
grant execute on function public.kuilu_order_action(uuid,text,uuid,jsonb) to authenticated;
create function kuilu_private.list_drivers() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if auth.uid() is null or not exists(select 1 from public.kuilu_profiles where id=auth.uid() and role in ('admin','china')) then raise exception '无权查看司机'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.username,u.email)) order by coalesce(p.username,u.email)),'[]') from public.kuilu_profiles p join auth.users u on p.id=u.id where p.role='driver');
end $$;
revoke all on function kuilu_private.list_drivers() from public,anon;
grant execute on function kuilu_private.list_drivers() to authenticated;
create function public.kuilu_list_drivers() returns jsonb language sql stable security invoker set search_path='' as $$ select kuilu_private.list_drivers() $$;
revoke all on function public.kuilu_list_drivers() from public,anon;
grant execute on function public.kuilu_list_drivers() to authenticated;

CREATE OR REPLACE FUNCTION public.kuilu_validate_order()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare cn public.kuilu_addresses%rowtype; jp public.kuilu_addresses%rowtype; item jsonb; path text; pickup date; delivery date; cargo_out jsonb:='[]';
begin
 if auth.uid() is null or new.user_id is distinct from auth.uid() then raise exception '登录身份不匹配'; end if;
 select * into cn from public.kuilu_addresses where id=new.cn_address_id and user_id=auth.uid() and country='CN' and status='approved';
 if not found then raise exception '中国取货地址未审核或无权使用'; end if;
 select * into jp from public.kuilu_addresses where id=new.jp_address_id and user_id=auth.uid() and country='JP' and status='approved';
 if not found then raise exception '日本配送地址未审核或无权使用'; end if;
 if jsonb_typeof(new.payload->'cargo') is distinct from 'array' then raise exception '缺少货物明细'; end if;
 if jsonb_array_length(new.payload->'cargo') not between 1 and 50 then raise exception '货物明细必须为 1 至 50 项'; end if;
 for item in select value from jsonb_array_elements(new.payload->'cargo') loop
  if jsonb_typeof(item) is distinct from 'object' then raise exception '货物明细格式错误'; end if;
  if coalesce(length(trim(item->>'name')),0) not between 1 and 200 then raise exception '商品名称不能为空'; end if;
  if coalesce(item->>'qty','') !~ '^[1-9][0-9]*$' or coalesce(item->>'boxes','') !~ '^[1-9][0-9]*$' then raise exception '商品数量与箱数必须为正整数'; end if;
  if new.payload->>'schemaVersion' is distinct from '2' and (coalesce(item->>'weight','') !~ '^[0-9]+([.][0-9]+)?$' or (item->>'weight')::numeric <= 0) then raise exception '申报重量必须大于零'; end if;
  if jsonb_typeof(item->'photos') is distinct from 'array' then raise exception '照片格式错误'; end if;
  if jsonb_array_length(item->'photos')>3 then raise exception '每项货物最多三张照片'; end if;
  if exists(select 1 from jsonb_array_elements(item->'photos') p(value) where jsonb_typeof(p.value) is distinct from 'string') then raise exception '照片路径必须是字符串'; end if;
  for path in select jsonb_array_elements_text(item->'photos') loop
   if path not like auth.uid()::text || '/' || new.id::text || '/%' or path ~ '(^|/)\.\.(/|$)' then raise exception '照片路径无效'; end if;
  end loop;

  if new.payload->>'schemaVersion'='2' then
   if coalesce(length(trim(item->>'nameEn')),0) not between 1 and 200 or coalesce(length(trim(item->>'packaging')),0) not between 1 and 80 then raise exception '请填写英文品名和包装类型'; end if;
   if coalesce(item->>'currency','') not in ('CNY','JPY','USD') or coalesce(item->>'unitPrice','') !~ '^[0-9]+([.][0-9]{1,2})?$' then raise exception '申报币别或单价无效'; end if;
   if (item->>'unitPrice')::numeric<=0 or (item->>'unitPrice')::numeric>999999999999 or (item->>'qty')::numeric>1000000 then raise exception '申报数值超出范围'; end if;
   item:=item||jsonb_build_object('declaredTotal',round((item->>'qty')::numeric*(item->>'unitPrice')::numeric,2));
  end if;
  cargo_out:=cargo_out||jsonb_build_array(item);
 end loop;
 new.payload:=jsonb_set(new.payload,'{cargo}',cargo_out);
 pickup := (new.payload->>'pickupDate')::date; delivery := pickup + 1;
 new.payload := new.payload || jsonb_build_object('deliveryDate',to_char(delivery,'YYYY-MM-DD'),'deliveryTime','12:00前','deliverySchedule','next_day_before_noon','deliveryTimezone','Asia/Tokyo');
 if pickup is null or delivery is null or pickup < (now() at time zone 'Asia/Shanghai')::date or delivery<pickup then raise exception '取货或配送日期无效'; end if;
 if coalesce(length(trim(new.payload->>'pickupContact')),0)=0 or coalesce(new.payload->>'pickupTime','')='' or coalesce(new.payload->>'deliveryTime','')='' then raise exception '联系人和时间段不能为空'; end if;
 new.address_snapshot := jsonb_build_object('cn',to_jsonb(cn),'jp',to_jsonb(jp));
 new.status := 'pending_review'; new.driver_id := null; new.created_at := now();
 return new;
end $function$;

notify pgrst,'reload schema';
