alter table public.kuilu_addresses alter column postal set default '';
alter table public.kuilu_addresses drop constraint kuilu_addresses_postal_check;
alter table public.kuilu_addresses add constraint kuilu_addresses_postal_check check (
 (country='CN' and length(trim(postal)) between 0 and 30)
 or (country='JP' and length(trim(postal)) between 1 and 30)
);
alter table public.kuilu_addresses alter column status set default 'approved';
drop policy kuilu_address_create on public.kuilu_addresses;
create policy kuilu_address_create on public.kuilu_addresses for insert to authenticated
with check(user_id=(select auth.uid()) and status='approved' and (select public.kuilu_role())='customer');
update public.kuilu_addresses set status='approved' where status='pending';
comment on column public.kuilu_addresses.status is 'approved 表示地址可用于下单，不代表已经经过人工审核；disabled 表示停用。地址由工作人员在接单时确认。';
notify pgrst,'reload schema';
