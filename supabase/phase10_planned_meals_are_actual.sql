-- Dynamack Rhythm Phase 10: selected meals are the default truth.
-- Manual food logs are only overrides (or snacks), so following the plan never
-- creates a second data-entry task. The original selection remains available
-- for planned-vs-changed learning.

create or replace function public.rhythm_effective_food(
  p_start date,
  p_end date
)
returns table (
  log_date date,
  food_slot text,
  food_name text,
  normalized_name text,
  source text,
  place_name text,
  meal_id uuid,
  occurred_at timestamptz,
  origin text
)
language sql
stable
security invoker
set search_path = public, pg_temp
as $function$
  with manual_main as (
    select distinct on (fle.log_date, fle.food_slot)
      fle.log_date, fle.food_slot, fle.food_name, fle.normalized_name,
      fle.source, fle.place_name, fle.meal_id, fle.occurred_at,
      'manual'::text as origin
    from public.food_log_entries fle
    where fle.owner_id = (select auth.uid())
      and fle.log_date between p_start and p_end
      and fle.food_slot in ('breakfast', 'lunch', 'dinner')
    order by fle.log_date, fle.food_slot, fle.occurred_at desc, fle.created_at desc
  ),
  manual_snacks as (
    select
      fle.log_date, fle.food_slot, fle.food_name, fle.normalized_name,
      fle.source, fle.place_name, fle.meal_id, fle.occurred_at,
      'manual'::text as origin
    from public.food_log_entries fle
    where fle.owner_id = (select auth.uid())
      and fle.log_date between p_start and p_end
      and fle.food_slot = 'snack'
  ),
  selected_meals as (
    select
      dp.plan_date as log_date,
      selected.food_slot,
      m.title as food_name,
      lower(regexp_replace(btrim(m.title), '\s+', ' ', 'g')) as normalized_name,
      'selected'::text as source,
      null::text as place_name,
      m.id as meal_id,
      coalesce(selected.selected_at, dp.created_at) as occurred_at,
      'selection'::text as origin
    from public.daily_plans dp
    cross join lateral (values
      ('breakfast'::text, dp.breakfast_meal_id, dp.breakfast_selected_at),
      ('lunch'::text, dp.lunch_meal_id, dp.lunch_selected_at),
      ('dinner'::text, dp.dinner_meal_id, dp.dinner_selected_at)
    ) selected(food_slot, meal_id, selected_at)
    join public.meals m
      on m.id = selected.meal_id
      and m.owner_id = (select auth.uid())
    where dp.owner_id = (select auth.uid())
      and dp.plan_date between p_start and p_end
      and not exists (
        select 1
        from public.food_log_entries fle
        where fle.owner_id = dp.owner_id
          and fle.log_date = dp.plan_date
          and fle.food_slot = selected.food_slot
      )
  )
  select * from manual_main
  union all
  select * from manual_snacks
  union all
  select * from selected_meals;
$function$;

revoke all on function public.rhythm_effective_food(date, date)
  from public, anon, service_role;
grant execute on function public.rhythm_effective_food(date, date)
  to authenticated;

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
  v_today_food jsonb := '[]'::jsonb;
  v_favorites jsonb := '[]'::jsonb;
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

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', fle.id,
    'slot', fle.food_slot,
    'foodName', fle.food_name,
    'source', fle.source,
    'placeName', fle.place_name,
    'mealId', fle.meal_id,
    'loggedAt', fle.occurred_at
  ) order by fle.occurred_at, fle.created_at), '[]'::jsonb)
  into v_today_food
  from public.food_log_entries fle
  where fle.owner_id = v_uid and fle.log_date = p_date;

  with grouped as (
    select
      effective.normalized_name,
      (array_agg(effective.food_name order by effective.occurred_at desc))[1] as display_name,
      count(*)::integer as times_chosen,
      count(distinct effective.log_date)::integer as days_chosen,
      max(effective.occurred_at) as last_chosen_at
    from public.rhythm_effective_food(p_date - 27, p_date) effective
    group by effective.normalized_name
    having count(*) >= 2 and count(distinct effective.log_date) >= 2
    order by times_chosen desc, last_chosen_at desc
    limit 3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'foodName', display_name,
    'timesChosen', times_chosen,
    'daysChosen', days_chosen
  ) order by times_chosen desc, last_chosen_at desc), '[]'::jsonb)
  into v_favorites from grouped;

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
    'foodLog', jsonb_build_object(
      'todayEntries', v_today_food,
      'favorites', v_favorites,
      'message', case when jsonb_array_length(v_favorites) = 0
        then 'Favorites appear after you choose or log the same food on more than one day.'
        else 'These are foods you come back to.' end
    ),
    'pantrySummary', jsonb_build_object(
      'available', coalesce(v_available, 0),
      'low', coalesce(v_low, 0),
      'trackingStyle', 'loose'
    )
  );
end;
$function$;

create or replace function public.rhythm_food_learning_context(p_days integer default 28)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_days integer := greatest(14, least(coalesce(p_days, 28), 28));
  v_start date := current_date - (greatest(14, least(coalesce(p_days, 28), 28)) - 1);
  v_aggregates jsonb := '{}'::jsonb;
  v_patterns jsonb := '[]'::jsonb;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  with recent as (
    select * from public.rhythm_effective_food(v_start, current_date)
  ),
  favorites as (
    select
      normalized_name,
      (array_agg(food_name order by occurred_at desc))[1] as food_name,
      count(*)::integer as times_chosen,
      count(distinct log_date)::integer as days_chosen,
      max(occurred_at) as last_chosen_at
    from recent
    group by normalized_name
    having count(*) >= 2 and count(distinct log_date) >= 2
  )
  select jsonb_build_object(
    'effectiveEntries', (select count(*)::integer from recent),
    'observedFoodDays', (select count(distinct log_date)::integer from recent),
    'favorites', coalesce((select jsonb_agg(jsonb_build_object(
      'foodName', food_name, 'timesChosen', times_chosen, 'daysChosen', days_chosen
    ) order by times_chosen desc, last_chosen_at desc) from favorites), '[]'::jsonb),
    'bySlot', coalesce((select jsonb_agg(jsonb_build_object('slot', food_slot, 'count', entry_count) order by food_slot)
      from (select food_slot, count(*)::integer entry_count from recent group by food_slot) slots), '[]'::jsonb),
    'bySource', coalesce((select jsonb_agg(jsonb_build_object('source', source, 'count', entry_count) order by source)
      from (select source, count(*)::integer entry_count from recent group by source) sources), '[]'::jsonb)
  ) into v_aggregates;

  with recent as (
    select * from public.rhythm_effective_food(v_start, current_date)
  ),
  favorite_patterns as (
    select
      'food_favorite_' || md5(normalized_name) as pattern_id,
      'food_favorite' as kind,
      jsonb_build_object(
        'foodName', (array_agg(food_name order by occurred_at desc))[1],
        'timesChosen', count(*)::integer,
        'daysChosen', count(distinct log_date)::integer
      ) as evidence,
      count(*) as strength
    from recent
    group by normalized_name
    having count(*) >= 2 and count(distinct log_date) >= 2
  ),
  source_patterns as (
    select
      'food_source_' || source as pattern_id,
      'food_source' as kind,
      jsonb_build_object(
        'source', source,
        'timesChosen', count(*)::integer,
        'daysChosen', count(distinct log_date)::integer
      ) as evidence,
      count(*) as strength
    from recent
    where source = 'eat_out'
    group by source
    having count(*) >= 3 and count(distinct log_date) >= 2
  ),
  place_patterns as (
    select
      'food_place_' || md5(lower(place_name)) as pattern_id,
      'food_place' as kind,
      jsonb_build_object(
        'placeName', (array_agg(place_name order by occurred_at desc))[1],
        'timesChosen', count(*)::integer,
        'daysChosen', count(distinct log_date)::integer
      ) as evidence,
      count(*) as strength
    from recent
    where source = 'eat_out' and place_name is not null
    group by lower(place_name)
    having count(*) >= 2 and count(distinct log_date) >= 2
  ),
  candidates as (
    select * from favorite_patterns
    union all
    select * from source_patterns
    union all
    select * from place_patterns
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pattern_id, 'kind', kind, 'evidence', evidence
  ) order by strength desc, pattern_id), '[]'::jsonb)
  into v_patterns
  from (select * from candidates order by strength desc, pattern_id limit 3) strongest;

  return jsonb_build_object(
    'foodAggregates', v_aggregates,
    'foodPatterns', v_patterns,
    'foodReady', jsonb_array_length(v_patterns) > 0,
    'foodWindowDays', v_days
  );
end;
$function$;

