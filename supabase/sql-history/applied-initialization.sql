-- 奎陆中日手提：客户下单 MVP。请在目标项目 SQL Editor 中执行一次。
-- 仅创建 kuilu_ 前缀业务表，不修改其他业务表或 auth.users。
create table public.kuilu_profiles (
 id uuid primary key references auth.users(id),
 role text not null default 'customer' check (role in ('customer','china','admin','driver')),
 created_at timestamptz not null default now()
);
alter table public.kuilu_profiles enable row level security;
revoke all on public.kuilu_profiles from anon, authenticated;
grant select, insert on public.kuilu_profiles to authenticated;
create policy kuilu_profile_read on public.kuilu_profiles for select to authenticated using (id = (select auth.uid()));
create policy kuilu_profile_create on public.kuilu_profiles for insert to authenticated with check (id = (select auth.uid()) and role = 'customer');

-- SECURITY INVOKER：角色来源为用户无法修改的数据库字段。
create function public.kuilu_role() returns text language sql stable security invoker
set search_path = '' as $$ select role from public.kuilu_profiles where id = (select auth.uid()) $$;
revoke all on function public.kuilu_role() from public, anon;
grant execute on function public.kuilu_role() to authenticated;

create table public.kuilu_addresses (
 id text primary key default ('ADR-' || gen_random_uuid()::text),
 user_id uuid not null default auth.uid() references public.kuilu_profiles(id),
 country text not null check(country in ('CN','JP')),
 name text not null check(length(trim(name)) between 1 and 150),
 contact text not null check(length(trim(contact)) between 1 and 150),
 phone text not null check(length(trim(phone)) between 1 and 50),
 postal text not null check(length(trim(postal)) between 1 and 30),
 region text not null check(length(trim(region)) between 1 and 300),
 street text not null check(length(trim(street)) between 1 and 500),
 status text not null default 'pending' check(status in ('pending','approved','disabled')),
 created_at timestamptz not null default now()
);
create index kuilu_addresses_owner on public.kuilu_addresses(user_id, country, created_at desc);
alter table public.kuilu_addresses enable row level security;
revoke all on public.kuilu_addresses from anon, authenticated;
grant select, insert on public.kuilu_addresses to authenticated;
grant update(status) on public.kuilu_addresses to authenticated;
create policy kuilu_address_read on public.kuilu_addresses for select to authenticated
using(user_id = (select auth.uid()) or (select public.kuilu_role()) = 'admin');
create policy kuilu_address_create on public.kuilu_addresses for insert to authenticated
with check(user_id = (select auth.uid()) and status = 'pending' and (select public.kuilu_role()) = 'customer');
create policy kuilu_address_review on public.kuilu_addresses for update to authenticated
using((select public.kuilu_role()) = 'admin') with check((select public.kuilu_role()) = 'admin');

create table public.kuilu_orders (
 id uuid primary key,
 order_number text not null unique default ('ORD-' || to_char(now(),'YYYYMMDD') || '-' || upper(gen_random_uuid()::text)),
 user_id uuid not null default auth.uid() references public.kuilu_profiles(id),
 cn_address_id text not null references public.kuilu_addresses(id),
 jp_address_id text not null references public.kuilu_addresses(id),
 payload jsonb not null check(jsonb_typeof(payload) = 'object'),
 address_snapshot jsonb not null default '{}'::jsonb,
 status text not null default 'pending_review' check(status in ('pending_review','approved','pickup','in_transit','arrived','delivering','delivered','cancelled')),
 driver_id uuid references public.kuilu_profiles(id),
 created_at timestamptz not null default now()
);
create index kuilu_orders_owner on public.kuilu_orders(user_id, created_at desc);
create index kuilu_orders_driver on public.kuilu_orders(driver_id, created_at desc);
create index kuilu_orders_cn_address on public.kuilu_orders(cn_address_id);
create index kuilu_orders_jp_address on public.kuilu_orders(jp_address_id);
create index kuilu_orders_status on public.kuilu_orders(status, created_at desc);
alter table public.kuilu_orders enable row level security;
revoke all on public.kuilu_orders from anon, authenticated;
grant select, insert on public.kuilu_orders to authenticated;
-- 本阶段仅开放只读工作人员订单视图；业务状态操作留给后续正式任务模块。
create policy kuilu_order_read on public.kuilu_orders for select to authenticated using (
 user_id = (select auth.uid()) or (select public.kuilu_role()) in ('admin','china')
 or ((select public.kuilu_role()) = 'driver' and driver_id = (select auth.uid()))
);
create policy kuilu_order_create on public.kuilu_orders for insert to authenticated with check (
 user_id = (select auth.uid()) and (select public.kuilu_role()) = 'customer'
 and status = 'pending_review' and driver_id is null
);

create function public.kuilu_validate_order() returns trigger language plpgsql security invoker set search_path = '' as $$
declare cn public.kuilu_addresses%rowtype; jp public.kuilu_addresses%rowtype; item jsonb; path text; pickup date; delivery date;
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
  if coalesce(item->>'weight','') !~ '^[0-9]+([.][0-9]+)?$' or (item->>'weight')::numeric <= 0 then raise exception '申报重量必须大于零'; end if;
  if jsonb_typeof(item->'photos') is distinct from 'array' then raise exception '照片格式错误'; end if;
  if jsonb_array_length(item->'photos')>3 then raise exception '每项货物最多三张照片'; end if;
  if exists(select 1 from jsonb_array_elements(item->'photos') p(value) where jsonb_typeof(p.value) is distinct from 'string') then raise exception '照片路径必须是字符串'; end if;
  for path in select jsonb_array_elements_text(item->'photos') loop
   if path not like auth.uid()::text || '/' || new.id::text || '/%' or path ~ '(^|/)\.\.(/|$)' then raise exception '照片路径无效'; end if;
  end loop;
 end loop;
 pickup := (new.payload->>'pickupDate')::date; delivery := (new.payload->>'deliveryDate')::date;
 if pickup is null or delivery is null or pickup < (now() at time zone 'Asia/Shanghai')::date or delivery<pickup then raise exception '取货或配送日期无效'; end if;
 if coalesce(length(trim(new.payload->>'pickupContact')),0)=0 or coalesce(new.payload->>'pickupTime','')='' or coalesce(new.payload->>'deliveryTime','')='' then raise exception '联系人和时间段不能为空'; end if;
 new.address_snapshot := jsonb_build_object('cn',to_jsonb(cn),'jp',to_jsonb(jp));
 new.status := 'pending_review'; new.driver_id := null; new.created_at := now();
 return new;
end $$;
revoke all on function public.kuilu_validate_order() from public, anon, authenticated;
create trigger kuilu_order_validation before insert on public.kuilu_orders for each row execute function public.kuilu_validate_order();

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('kuilu-cargo','kuilu-cargo',false,2097152,array['image/jpeg','image/png','image/webp']);
create policy kuilu_photo_upload on storage.objects for insert to authenticated with check (
 bucket_id='kuilu-cargo' and (storage.foldername(name))[1] = (select auth.uid())::text
 and (select public.kuilu_role())='customer'
);
create policy kuilu_photo_read on storage.objects for select to authenticated using (
 bucket_id='kuilu-cargo' and (
  (storage.foldername(name))[1] = (select auth.uid())::text
  or (select public.kuilu_role()) in ('admin','china')
  or exists(select 1 from public.kuilu_orders o where o.id::text=(storage.foldername(name))[2] and o.driver_id=(select auth.uid()) and (select public.kuilu_role())='driver')
 )
);
-- 允许客户清理未提交订单产生的照片；已提交订单的照片不可由客户删除。
create policy kuilu_photo_cleanup on storage.objects for delete to authenticated using (
 bucket_id='kuilu-cargo' and (storage.foldername(name))[1] = (select auth.uid())::text
 and not exists(select 1 from public.kuilu_orders o where o.id::text=(storage.foldername(name))[2])
);

notify pgrst, 'reload schema';

