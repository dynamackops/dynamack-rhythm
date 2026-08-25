-- Dynamack Rhythm Phase 9: a gentle actual-food log and evidence-based favorites.
-- Planned meals remain on daily_plans. This table records what was actually eaten,
-- including multiple snacks and meals away from home.

create table if not exists public.food_log_entries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  daily_plan_id uuid not null references public.daily_plans(id) on delete cascade,
  log_date date not null,
  food_slot text not null check (food_slot in ('breakfast', 'lunch', 'dinner', 'snack')),
  food_name text not null check (char_length(btrim(food_name)) between 1 and 120),
  normalized_name text not null check (char_length(normalized_name) between 1 and 120),
  source text not null default 'home' check (source in ('home', 'eat_out')),
  place_name text check (place_name is null or char_length(btrim(place_name)) between 1 and 80),
  meal_id uuid references public.meals(id) on delete set null,
  occurred_at timestamptz not null default clock_timestamp(),
  created_at timestamptz not null default clock_timestamp()
);

create index if not exists food_log_owner_date_idx
  on public.food_log_entries (owner_id, log_date desc, occurred_at desc);
create index if not exists food_log_owner_name_idx
  on public.food_log_entries (owner_id, normalized_name, log_date desc);
create index if not exists food_log_daily_plan_idx
  on public.food_log_entries (daily_plan_id);
create index if not exists food_log_meal_idx
  on public.food_log_entries (meal_id) where meal_id is not null;

alter table public.food_log_entries enable row level security;

drop policy if exists "private owner reads food log" on public.food_log_entries;
create policy "private owner reads food log"
on public.food_log_entries for select to authenticated
using ((select auth.uid()) = owner_id);

drop policy if exists "private owner adds food log" on public.food_log_entries;
create policy "private owner adds food log"
on public.food_log_entries for insert to authenticated
with check (
  (select auth.uid()) = owner_id
  and exists (
    select 1 from public.daily_plans dp
    where dp.id = daily_plan_id and dp.owner_id = (select auth.uid())
  )
);

drop policy if exists "private owner removes food log" on public.food_log_entries;
create policy "private owner removes food log"
on public.food_log_entries for delete to authenticated
using ((select auth.uid()) = owner_id);

revoke all on table public.food_log_entries from public, anon;
grant select, insert, delete on table public.food_log_entries to authenticated;
grant select, insert, update, delete on table public.food_log_entries to service_role;

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
      fle.normalized_name,
      (array_agg(fle.food_name order by fle.occurred_at desc))[1] as display_name,
      count(*)::integer as times_logged,
      count(distinct fle.log_date)::integer as days_logged,
      max(fle.occurred_at) as last_logged_at
    from public.food_log_entries fle
    where fle.owner_id = v_uid and fle.log_date >= p_date - 27
    group by fle.normalized_name
    having count(*) >= 2 and count(distinct fle.log_date) >= 2
    order by times_logged desc, last_logged_at desc
    limit 3
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'foodName', display_name,
    'timesLogged', times_logged,
    'daysLogged', days_logged
  ) order by times_logged desc, last_logged_at desc), '[]'::jsonb)
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
        then 'Favorites appear gently after the same food is logged on more than one day.'
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

create or replace function public.rhythm_food_log_action(
  p_action text,
  p_date date,
  p_food_name text default null,
  p_food_slot text default null,
  p_source text default 'home',
  p_place_name text default null,
  p_log_id uuid default null,
  p_meal_id uuid default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_plan_id uuid;
  v_name text := btrim(coalesce(p_food_name, ''));
  v_normalized text;
  v_source text := coalesce(nullif(p_source, ''), 'home');
  v_place text := nullif(btrim(coalesce(p_place_name, '')), '');
  v_message text;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;
  if p_action not in ('log_food', 'delete_food_log') then
    raise exception 'Unsupported food log action.' using errcode = '22023';
  end if;

  if p_action = 'log_food' then
    if char_length(v_name) not between 1 and 120 then
      raise exception 'Type a food name up to 120 characters.' using errcode = '22023';
    end if;
    if p_food_slot not in ('breakfast', 'lunch', 'dinner', 'snack') then
      raise exception 'Choose breakfast, lunch, dinner, or snack.' using errcode = '22023';
    end if;
    if v_source not in ('home', 'eat_out') then
      raise exception 'Unknown food source.' using errcode = '22023';
    end if;
    if v_place is not null and char_length(v_place) > 80 then
      raise exception 'Keep the place name under 80 characters.' using errcode = '22023';
    end if;
    if p_meal_id is not null and not exists (
      select 1 from public.meals m where m.id = p_meal_id and m.owner_id = v_uid
    ) then
      raise exception 'That saved meal was not found.' using errcode = '22023';
    end if;

    select dp.id into v_plan_id
    from public.daily_plans dp
    where dp.owner_id = v_uid and dp.plan_date = p_date;
    if v_plan_id is null then
      raise exception 'Build today before logging food.' using errcode = '22023';
    end if;

    v_normalized := lower(regexp_replace(v_name, '\s+', ' ', 'g'));
    insert into public.food_log_entries (
      owner_id, daily_plan_id, log_date, food_slot, food_name,
      normalized_name, source, place_name, meal_id
    ) values (
      v_uid, v_plan_id, p_date, p_food_slot, v_name,
      v_normalized, v_source, case when v_source = 'eat_out' then v_place else null end, p_meal_id
    );
    v_message := 'Logged ' || v_name || '. No numbers, just a memory for later.';
  else
    if p_log_id is null then
      raise exception 'Choose a food log entry first.' using errcode = '22023';
    end if;
    delete from public.food_log_entries
    where id = p_log_id and owner_id = v_uid and log_date = p_date;
    if not found then
      raise exception 'That food log entry was not found.' using errcode = '22023';
    end if;
    v_message := 'Removed that food entry.';
  end if;

  return public.rhythm_phase4_action('get_state', p_date)
    || public.rhythm_meal_state(p_date)
    || jsonb_build_object(
      'action', p_action,
      'foodLogChange', jsonb_build_object('changed', true, 'message', v_message)
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
    select * from public.food_log_entries
    where owner_id = v_uid and log_date >= v_start
  ),
  favorites as (
    select
      normalized_name,
      (array_agg(food_name order by occurred_at desc))[1] as food_name,
      count(*)::integer as times_logged,
      count(distinct log_date)::integer as days_logged,
      max(occurred_at) as last_logged_at
    from recent
    group by normalized_name
    having count(*) >= 2 and count(distinct log_date) >= 2
  )
  select jsonb_build_object(
    'loggedEntries', (select count(*)::integer from recent),
    'loggedDays', (select count(distinct log_date)::integer from recent),
    'favorites', coalesce((select jsonb_agg(jsonb_build_object(
      'foodName', food_name, 'timesLogged', times_logged, 'daysLogged', days_logged
    ) order by times_logged desc, last_logged_at desc) from favorites), '[]'::jsonb),
    'bySlot', coalesce((select jsonb_agg(jsonb_build_object('slot', food_slot, 'count', entry_count) order by food_slot)
      from (select food_slot, count(*)::integer entry_count from recent group by food_slot) slots), '[]'::jsonb),
    'bySource', coalesce((select jsonb_agg(jsonb_build_object('source', source, 'count', entry_count) order by source)
      from (select source, count(*)::integer entry_count from recent group by source) sources), '[]'::jsonb)
  ) into v_aggregates;

  with recent as (
    select * from public.food_log_entries
    where owner_id = v_uid and log_date >= v_start
  ),
  favorite_patterns as (
    select
      'food_favorite_' || md5(normalized_name) as pattern_id,
      'food_favorite' as kind,
      jsonb_build_object(
        'foodName', (array_agg(food_name order by occurred_at desc))[1],
        'timesLogged', count(*)::integer,
        'daysLogged', count(distinct log_date)::integer
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
        'timesLogged', count(*)::integer,
        'daysLogged', count(distinct log_date)::integer
      ) as evidence,
      count(*) as strength
    from recent
    group by source
    having count(*) >= 3 and count(distinct log_date) >= 2
  ),
  candidates as (
    select * from favorite_patterns
    union all
    select * from source_patterns
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

create or replace function public.rhythm_learning_context_v2(p_days integer default 28)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_base jsonb := public.rhythm_learning_context(p_days);
  v_food jsonb := public.rhythm_food_learning_context(p_days);
begin
  return v_base || jsonb_build_object(
    'ready', coalesce((v_base->>'ready')::boolean, false) or coalesce((v_food->>'foodReady')::boolean, false),
    'patterns', coalesce(v_base->'patterns', '[]'::jsonb) || coalesce(v_food->'foodPatterns', '[]'::jsonb),
    'aggregates', coalesce(v_base->'aggregates', '{}'::jsonb)
      || jsonb_build_object('food', coalesce(v_food->'foodAggregates', '{}'::jsonb))
  );
end;
$function$;

revoke all on function public.rhythm_food_log_action(text, date, text, text, text, text, uuid, uuid)
  from public, anon, service_role;
revoke all on function public.rhythm_food_learning_context(integer)
  from public, anon, service_role;
revoke all on function public.rhythm_learning_context_v2(integer)
  from public, anon, service_role;
grant execute on function public.rhythm_food_log_action(text, date, text, text, text, text, uuid, uuid)
  to authenticated;
grant execute on function public.rhythm_food_learning_context(integer) to authenticated;
grant execute on function public.rhythm_learning_context_v2(integer) to authenticated;

-- The user explicitly confirmed these two meals were eaten on August 24.
insert into public.food_log_entries (
  owner_id, daily_plan_id, log_date, food_slot, food_name,
  normalized_name, source, meal_id, occurred_at
)
select
  dp.owner_id, dp.id, dp.plan_date, seed.food_slot, seed.food_name,
  lower(seed.food_name), 'home', m.id,
  (dp.plan_date::timestamp + seed.local_time) at time zone 'America/New_York'
from public.daily_plans dp
cross join (values
  ('breakfast', 'Chocolate PB berry shake', time '09:00'),
  ('lunch', 'Thai tuna over white rice', time '12:30')
) as seed(food_slot, food_name, local_time)
join public.meals m on m.owner_id = dp.owner_id
  and m.meal_key = case seed.food_slot when 'breakfast' then 'protein_smoothie' else 'thai_tuna_rice' end
where dp.plan_date = date '2026-08-24'
  and not exists (
    select 1 from public.food_log_entries fle
    where fle.owner_id = dp.owner_id and fle.log_date = dp.plan_date
      and fle.food_slot = seed.food_slot and fle.normalized_name = lower(seed.food_name)
  );

notify pgrst, 'reload schema';
