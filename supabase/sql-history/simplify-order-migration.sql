alter table public.kuilu_addresses drop constraint kuilu_addresses_postal_check;
alter table public.kuilu_addresses add constraint kuilu_addresses_postal_check check(length(trim(postal))<=30);
alter table public.kuilu_product_presets drop constraint kuilu_product_presets_name_en_check;
alter table public.kuilu_product_presets alter column name_en set default '';
alter table public.kuilu_product_presets add constraint kuilu_product_presets_name_en_check check(length(name_en)<=200);
CREATE OR REPLACE FUNCTION public.kuilu_validate_order()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare cn public.kuilu_addresses%rowtype; jp public.kuilu_addresses%rowtype; item jsonb; path text; pickup date; delivery date; cargo_out jsonb:='[]';
begin
 if new.payload->>'schemaVersion'='3' then new.payload:=new.payload||jsonb_build_object('pickupTime','当天联系确认'); end if;
 if auth.uid() is null or new.user_id is distinct from auth.uid() then raise exception '登录身份不匹配'; end if;
 select * into cn from public.kuilu_addresses where id=new.cn_address_id and user_id=auth.uid() and country='CN' and status='approved';
 if not found then raise exception '中国取货地址未审核或无权使用'; end if;
 select * into jp from public.kuilu_addresses where id=new.jp_address_id and user_id=auth.uid() and country='JP' and status='approved';
 if not found then raise exception '日本配送地址未审核或无权使用'; end if;
 if jsonb_typeof(new.payload->'cargo') is distinct from 'array' then raise exception '缺少货物明细'; end if;
 if jsonb_array_length(new.payload->'cargo') not between 1 and 50 then raise exception '货物明细必须为 1 至 50 项'; end if;
 for item in select value from jsonb_array_elements(new.payload->'cargo') loop
  if new.payload->>'schemaVersion'='3' then item:=(item-'nameEn')||jsonb_build_object('boxes',1);end if;
  if jsonb_typeof(item) is distinct from 'object' then raise exception '货物明细格式错误'; end if;
  if coalesce(length(trim(item->>'name')),0) not between 1 and 200 then raise exception '商品名称不能为空'; end if;
  if coalesce(item->>'qty','') !~ '^[1-9][0-9]*$' or coalesce(item->>'boxes','') !~ '^[1-9][0-9]*$' then raise exception '商品数量与箱数必须为正整数'; end if;
  if coalesce(new.payload->>'schemaVersion','1') not in ('2','3') and (coalesce(item->>'weight','') !~ '^[0-9]+([.][0-9]+)?$' or (item->>'weight')::numeric <= 0) then raise exception '申报重量必须大于零'; end if;
  if jsonb_typeof(item->'photos') is distinct from 'array' then raise exception '照片格式错误'; end if;
  if jsonb_array_length(item->'photos')>3 then raise exception '每项货物最多三张照片'; end if;
  if exists(select 1 from jsonb_array_elements(item->'photos') p(value) where jsonb_typeof(p.value) is distinct from 'string') then raise exception '照片路径必须是字符串'; end if;
  for path in select jsonb_array_elements_text(item->'photos') loop
   if path not like auth.uid()::text || '/' || new.id::text || '/%' or path ~ '(^|/)\.\.(/|$)' then raise exception '照片路径无效'; end if;
  end loop;

  if new.payload->>'schemaVersion' in ('2','3') then
   if coalesce(length(trim(item->>'packaging')),0) not between 1 and 80 then raise exception '请填写包装类型'; end if;
   if new.payload->>'schemaVersion'='3' and item->>'packaging' not in ('纸箱','袋子') then raise exception '请选择纸箱或袋子';end if;
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
