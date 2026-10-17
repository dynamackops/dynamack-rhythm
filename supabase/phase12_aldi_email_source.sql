create or replace function public.rhythm_import_grocery_receipt(
  p_source_reference text,
  p_purchased_on date,
  p_items jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_owner_id uuid := auth.uid();
  v_import_id uuid;
  v_item jsonb;
  v_item_key text;
  v_name text;
  v_category text;
  v_count integer;
begin
  if v_owner_id is null then
    raise exception 'Authentication required' using errcode = '28000';
  end if;
  if p_source_reference is null or length(p_source_reference) < 1 or length(p_source_reference) > 200 then
    raise exception 'Invalid receipt reference' using errcode = '22023';
  end if;
  if jsonb_typeof(p_items) <> 'array' then
    raise exception 'Items must be an array' using errcode = '22023';
  end if;
  v_count := jsonb_array_length(p_items);
  if v_count < 1 or v_count > 80 then
    raise exception 'Receipt must contain between 1 and 80 selected items' using errcode = '22023';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_items) as x(value)
    where jsonb_typeof(value) <> 'object'
      or coalesce(length(trim(value->>'item_key')), 0) not between 1 and 100
      or coalesce(length(trim(value->>'name')), 0) not between 1 and 120
      or value->>'category' not in ('protein','grain','vegetable','fruit','breakfast','snack','drink','dessert','other')
  ) then
    raise exception 'Receipt item contains invalid fields' using errcode = '22023';
  end if;
  if (select count(distinct value->>'item_key') from jsonb_array_elements(p_items) as x(value)) <> v_count then
    raise exception 'Receipt contains duplicate item keys' using errcode = '22023';
  end if;

  insert into public.grocery_imports(owner_id, source, purchased_on, item_count, note, item_summary, source_reference)
  values (v_owner_id, 'aldi_email', coalesce(p_purchased_on, current_date), v_count,
          'Imported from a reviewed Instacart Aldi receipt', p_items, p_source_reference)
  on conflict (owner_id, source_reference) where source_reference is not null do nothing
  returning id into v_import_id;

  if v_import_id is null then
    return jsonb_build_object('ok', true, 'alreadyImported', true, 'itemsUpdated', 0);
  end if;

  for v_item in select value from jsonb_array_elements(p_items) as x(value)
  loop
    v_item_key := trim(v_item->>'item_key');
    v_name := trim(v_item->>'name');
    v_category := v_item->>'category';
    insert into public.pantry_items(
      owner_id, item_key, name, category, stock_status, quantity_estimate, unit,
      source, last_import_id, last_seen_at
    )
    values (v_owner_id, v_item_key, v_name, v_category, 'available', null, null,
            'aldi_email', v_import_id, now())
    on conflict (owner_id, item_key) do update
      set name = excluded.name,
          category = excluded.category,
          stock_status = 'available',
          source = 'aldi_email',
          last_import_id = v_import_id,
          last_seen_at = now(),
          updated_at = now();
  end loop;

  return jsonb_build_object('ok', true, 'alreadyImported', false, 'itemsUpdated', v_count);
end;
$$;

revoke all on function public.rhythm_import_grocery_receipt(text, date, jsonb) from public, anon;
grant execute on function public.rhythm_import_grocery_receipt(text, date, jsonb) to authenticated;
