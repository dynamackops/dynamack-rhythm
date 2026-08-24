-- Dynamack Rhythm Phase 8: breakfast, lunch, and dinner planning.
-- Reuses the existing meal library and daily plan rather than creating another table.

alter table public.daily_plans
  add column if not exists breakfast_meal_id uuid references public.meals(id) on delete set null,
  add column if not exists breakfast_selected_at timestamptz,
  add column if not exists lunch_meal_id uuid references public.meals(id) on delete set null,
  add column if not exists lunch_selected_at timestamptz;

alter table public.meals
  add column if not exists meal_slots text[] not null
    default array['breakfast', 'lunch', 'dinner']::text[];

alter table public.meals
  drop constraint if exists meals_valid_meal_slots;
alter table public.meals
  add constraint meals_valid_meal_slots check (
    cardinality(meal_slots) > 0
    and meal_slots <@ array['breakfast', 'lunch', 'dinner']::text[]
  );

-- Cover the new foreign keys. These may appear unused until normal meal-plan
-- traffic accumulates, but avoid full scans during referenced-meal changes.
create index if not exists daily_plans_breakfast_meal_id_idx
  on public.daily_plans (breakfast_meal_id);
create index if not exists daily_plans_lunch_meal_id_idx
  on public.daily_plans (lunch_meal_id);

update public.meals
set meal_slots = case meal_key
  when 'salmon_rice_vegetables' then array['lunch', 'dinner']::text[]
  when 'thai_tuna_rice' then array['lunch', 'dinner']::text[]
  when 'tuna_crackers' then array['lunch', 'dinner']::text[]
  when 'protein_smoothie' then array['breakfast', 'lunch', 'dinner']::text[]
  when 'cottage_grapes' then array['breakfast', 'lunch', 'dinner']::text[]
  when 'turkey_pasta' then array['lunch', 'dinner']::text[]
  when 'waffles_shake' then array['breakfast']::text[]
  when 'protein_shake_crackers' then array['breakfast', 'lunch', 'dinner']::text[]
  when 'breakfast_sandwich_grapes' then array['breakfast']::text[]
  else meal_slots
end;

create or replace function public.rhythm_meal_state(p_date date)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_breakfast jsonb;
  v_lunch jsonb;
  v_dinner jsonb;
  v_available integer;
  v_low integer;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'id', m.id, 'title', m.title, 'effort', m.effort, 'minutes', m.minutes,
    'instructions', m.instructions, 'supportiveNote', m.supportive_note,
    'selectedAt', dp.breakfast_selected_at
  ) into v_breakfast
  from public.daily_plans dp
  join public.meals m on m.id = dp.breakfast_meal_id and m.owner_id = v_uid
  where dp.owner_id = v_uid and dp.plan_date = p_date limit 1;

  select jsonb_build_object(
    'id', m.id, 'title', m.title, 'effort', m.effort, 'minutes', m.minutes,
    'instructions', m.instructions, 'supportiveNote', m.supportive_note,
    'selectedAt', dp.lunch_selected_at
  ) into v_lunch
  from public.daily_plans dp
  join public.meals m on m.id = dp.lunch_meal_id and m.owner_id = v_uid
  where dp.owner_id = v_uid and dp.plan_date = p_date limit 1;

  select jsonb_build_object(
    'id', m.id, 'title', m.title, 'effort', m.effort, 'minutes', m.minutes,
    'instructions', m.instructions, 'supportiveNote', m.supportive_note,
    'selectedAt', dp.dinner_selected_at
  ) into v_dinner
  from public.daily_plans dp
  join public.meals m on m.id = dp.dinner_meal_id and m.owner_id = v_uid
  where dp.owner_id = v_uid and dp.plan_date = p_date limit 1;

  select
    count(*) filter (where stock_status = 'available'),
    count(*) filter (where stock_status = 'low')
  into v_available, v_low
  from public.pantry_items where owner_id = v_uid;

  return jsonb_build_object(
    'mealPlan', jsonb_build_object(
      'breakfast', coalesce(v_breakfast, 'null'::jsonb),
      'lunch', coalesce(v_lunch, 'null'::jsonb),
      'dinner', coalesce(v_dinner, 'null'::jsonb)
    ),
    'breakfastChoice', coalesce(v_breakfast, 'null'::jsonb),
    'lunchChoice', coalesce(v_lunch, 'null'::jsonb),
    'dinnerChoice', coalesce(v_dinner, 'null'::jsonb),
    'pantrySummary', jsonb_build_object(
      'available', coalesce(v_available, 0),
      'low', coalesce(v_low, 0),
      'trackingStyle', 'loose'
    )
  );
end;
$function$;

create or replace function public.rhythm_all_day_meal_action(
  p_action text,
  p_date date,
  p_effort text default null,
  p_meal_id uuid default null,
  p_pantry_item_id uuid default null,
  p_meal_slot text default 'dinner'
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_base jsonb;
  v_choices jsonb := '[]'::jsonb;
  v_effort text;
  v_slot text := coalesce(nullif(p_meal_slot, ''), 'dinner');
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;
  if p_action not in ('meal_help', 'select_meal', 'pantry_gone') then
    raise exception 'Unsupported meal action: %', p_action using errcode = '22023';
  end if;
  if v_slot not in ('breakfast', 'lunch', 'dinner') then
    raise exception 'Unknown meal slot.' using errcode = '22023';
  end if;

  v_base := public.rhythm_phase4_action('get_state', p_date);

  if p_action = 'select_meal' then
    if p_meal_id is null then
      raise exception 'Choose a meal first.' using errcode = '22023';
    end if;
    if not exists (
      select 1 from public.meals m
      where m.id = p_meal_id and m.owner_id = v_uid and m.active
        and v_slot = any(m.meal_slots)
    ) then
      raise exception 'That meal is not available for this part of the day.' using errcode = '22023';
    end if;

    update public.daily_plans
    set breakfast_meal_id = case when v_slot = 'breakfast' then p_meal_id else breakfast_meal_id end,
        breakfast_selected_at = case when v_slot = 'breakfast' then clock_timestamp() else breakfast_selected_at end,
        lunch_meal_id = case when v_slot = 'lunch' then p_meal_id else lunch_meal_id end,
        lunch_selected_at = case when v_slot = 'lunch' then clock_timestamp() else lunch_selected_at end,
        dinner_meal_id = case when v_slot = 'dinner' then p_meal_id else dinner_meal_id end,
        dinner_selected_at = case when v_slot = 'dinner' then clock_timestamp() else dinner_selected_at end,
        updated_at = clock_timestamp()
    where owner_id = v_uid and plan_date = p_date;
    if not found then
      raise exception 'Build today before choosing a meal.' using errcode = '22023';
    end if;
  elsif p_action = 'pantry_gone' then
    if p_pantry_item_id is null then
      raise exception 'Choose a pantry item first.' using errcode = '22023';
    end if;
    update public.pantry_items
    set stock_status = 'gone', updated_at = clock_timestamp()
    where id = p_pantry_item_id and owner_id = v_uid;
    if not found then
      raise exception 'That pantry item was not found.' using errcode = '22023';
    end if;
  end if;

  if p_action = 'meal_help' then
    v_effort := coalesce(nullif(p_effort, ''), case
      when coalesce(v_base->>'energyMode', 'normal') in ('recovery', 'overwhelmed') then 'no_cook'
      when coalesce(v_base->>'energyMode', 'normal') = 'low_energy' then 'very_easy'
      else 'any'
    end);
    if v_effort not in ('any', 'no_cook', 'very_easy', 'cook_a_little') then
      raise exception 'Unknown meal effort.' using errcode = '22023';
    end if;

    select coalesce(jsonb_agg(choice order by rank_order, sort_order), '[]'::jsonb)
    into v_choices
    from (
      select
        jsonb_build_object(
          'id', m.id, 'title', m.title, 'effort', m.effort, 'minutes', m.minutes,
          'instructions', m.instructions, 'equipment', to_jsonb(m.equipment),
          'supportiveNote', m.supportive_note, 'mealSlot', v_slot,
          'ingredients', coalesce((
            select jsonb_agg(jsonb_build_object(
              'key', mi.item_key, 'name', mi.ingredient_name, 'required', mi.required
            ) order by mi.created_at)
            from public.meal_ingredients mi where mi.meal_id = m.id
          ), '[]'::jsonb)
        ) as choice,
        case when v_effort = 'any' or m.effort = v_effort then 0 else 1 end as rank_order,
        m.sort_order
      from public.meals m
      where m.owner_id = v_uid and m.active and v_slot = any(m.meal_slots)
        and (v_effort = 'any' or m.effort = v_effort)
        and not exists (
          select 1 from public.meal_ingredients mi
          where mi.meal_id = m.id and mi.required
            and not exists (
              select 1 from public.pantry_items pi
              where pi.owner_id = v_uid and pi.item_key = mi.item_key
                and pi.stock_status in ('available', 'low')
            )
        )
      order by rank_order, m.sort_order
      limit 3
    ) ranked;
  end if;

  return v_base
    || public.rhythm_meal_state(p_date)
    || jsonb_build_object(
      'action', p_action,
      'mealSlot', v_slot,
      'mealChoices', case when p_action = 'meal_help' then v_choices else 'null'::jsonb end
    );
end;
$function$;

revoke all on function public.rhythm_all_day_meal_action(text, date, text, uuid, uuid, text)
  from public, anon, service_role;
grant execute on function public.rhythm_all_day_meal_action(text, date, text, uuid, uuid, text)
  to authenticated;

-- Correct today's real choices: smoothie for breakfast, Thai tuna and rice for lunch.
update public.daily_plans dp
set breakfast_meal_id = (
      select m.id from public.meals m
      where m.owner_id = dp.owner_id and m.meal_key = 'protein_smoothie'
    ),
    breakfast_selected_at = coalesce(dp.breakfast_selected_at, clock_timestamp()),
    lunch_meal_id = (
      select m.id from public.meals m
      where m.owner_id = dp.owner_id and m.meal_key = 'thai_tuna_rice'
    ),
    lunch_selected_at = coalesce(dp.lunch_selected_at, clock_timestamp()),
    dinner_meal_id = case
      when dp.dinner_meal_id = (
        select m.id from public.meals m
        where m.owner_id = dp.owner_id and m.meal_key = 'thai_tuna_rice'
      ) then null else dp.dinner_meal_id end,
    dinner_selected_at = case
      when dp.dinner_meal_id = (
        select m.id from public.meals m
        where m.owner_id = dp.owner_id and m.meal_key = 'thai_tuna_rice'
      ) then null else dp.dinner_selected_at end,
    updated_at = clock_timestamp()
where dp.plan_date = date '2026-08-24'
  and exists (select 1 from public.meals m where m.owner_id = dp.owner_id and m.meal_key = 'protein_smoothie')
  and exists (select 1 from public.meals m where m.owner_id = dp.owner_id and m.meal_key = 'thai_tuna_rice');

notify pgrst, 'reload schema';
