-- Rhythm Agent Phase 4: low-maintenance pantry + deterministic Meal Chooser.
-- Pantry quantities are intentionally optional. The primary state is available / low / gone.

create table if not exists public.grocery_imports (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  source text not null default 'shopping_upload',
  purchased_on date not null default current_date,
  item_count smallint not null default 0 check (item_count >= 0),
  note text check (note is null or char_length(note) <= 280),
  item_summary jsonb not null default '[]'::jsonb check (jsonb_typeof(item_summary) = 'array'),
  created_at timestamptz not null default now()
);

create table if not exists public.pantry_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  item_key text not null,
  name text not null,
  category text not null check (category in ('protein', 'grain', 'vegetable', 'fruit', 'breakfast', 'snack', 'drink', 'dessert', 'other')),
  stock_status text not null default 'available' check (stock_status in ('available', 'low', 'gone')),
  quantity_estimate numeric(8,2) check (quantity_estimate is null or quantity_estimate >= 0),
  unit text,
  source text not null default 'manual',
  last_import_id uuid references public.grocery_imports(id) on delete set null,
  last_seen_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, item_key)
);

create table if not exists public.meals (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  meal_key text not null,
  title text not null,
  effort text not null check (effort in ('no_cook', 'very_easy', 'cook_a_little')),
  minutes smallint not null check (minutes between 1 and 120),
  instructions text not null,
  equipment text[] not null default '{}',
  supportive_note text,
  active boolean not null default true,
  sort_order smallint not null default 100,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, meal_key)
);

create table if not exists public.meal_ingredients (
  id uuid primary key default gen_random_uuid(),
  meal_id uuid not null references public.meals(id) on delete cascade,
  item_key text not null,
  ingredient_name text not null,
  required boolean not null default true,
  created_at timestamptz not null default now(),
  unique (meal_id, item_key)
);

alter table public.daily_plans
  add column if not exists dinner_meal_id uuid references public.meals(id) on delete set null,
  add column if not exists dinner_selected_at timestamptz;

create index if not exists grocery_imports_owner_date_idx
  on public.grocery_imports (owner_id, purchased_on desc);
create index if not exists pantry_items_owner_status_idx
  on public.pantry_items (owner_id, stock_status, category);
create index if not exists pantry_items_last_import_id_idx
  on public.pantry_items (last_import_id);
create index if not exists meals_owner_effort_idx
  on public.meals (owner_id, active, effort, sort_order);
create index if not exists meal_ingredients_meal_id_idx
  on public.meal_ingredients (meal_id);
create index if not exists daily_plans_dinner_meal_id_idx
  on public.daily_plans (dinner_meal_id);

alter table public.grocery_imports enable row level security;
alter table public.pantry_items enable row level security;
alter table public.meals enable row level security;
alter table public.meal_ingredients enable row level security;

drop policy if exists "private owner reads grocery imports" on public.grocery_imports;
create policy "private owner reads grocery imports"
on public.grocery_imports for select to authenticated
using (
  (select auth.uid()) = owner_id
);

drop policy if exists "private owner creates grocery imports" on public.grocery_imports;
create policy "private owner creates grocery imports"
on public.grocery_imports for insert to authenticated
with check (
  (select auth.uid()) = owner_id
);

drop policy if exists "private owner reads pantry" on public.pantry_items;
create policy "private owner reads pantry"
on public.pantry_items for select to authenticated
using (
  (select auth.uid()) = owner_id
);

drop policy if exists "private owner creates pantry" on public.pantry_items;
create policy "private owner creates pantry"
on public.pantry_items for insert to authenticated
with check (
  (select auth.uid()) = owner_id
);

drop policy if exists "private owner updates pantry" on public.pantry_items;
create policy "private owner updates pantry"
on public.pantry_items for update to authenticated
using (
  (select auth.uid()) = owner_id
)
with check (
  (select auth.uid()) = owner_id
);

drop policy if exists "private owner reads meals" on public.meals;
create policy "private owner reads meals"
on public.meals for select to authenticated
using (
  (select auth.uid()) = owner_id
);

drop policy if exists "private owner reads meal ingredients" on public.meal_ingredients;
create policy "private owner reads meal ingredients"
on public.meal_ingredients for select to authenticated
using (
  exists (
    select 1 from public.meals m
    where m.id = meal_ingredients.meal_id
      and m.owner_id = (select auth.uid())
  )
);

revoke all on table public.grocery_imports, public.pantry_items, public.meals, public.meal_ingredients from anon;
grant select, insert on table public.grocery_imports to authenticated;
grant select, insert, update on table public.pantry_items to authenticated;
grant select on table public.meals, public.meal_ingredients to authenticated;
grant select, insert, update, delete on table public.grocery_imports, public.pantry_items, public.meals, public.meal_ingredients to service_role;

create or replace function public.rhythm_meal_state(p_date date)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_dinner jsonb;
  v_available integer;
  v_low integer;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  select jsonb_build_object(
    'id', m.id,
    'title', m.title,
    'effort', m.effort,
    'minutes', m.minutes,
    'instructions', m.instructions,
    'supportiveNote', m.supportive_note,
    'selectedAt', dp.dinner_selected_at
  ) into v_dinner
  from public.daily_plans dp
  join public.meals m on m.id = dp.dinner_meal_id and m.owner_id = v_uid
  where dp.owner_id = v_uid and dp.plan_date = p_date
  limit 1;

  select
    count(*) filter (where stock_status = 'available'),
    count(*) filter (where stock_status = 'low')
  into v_available, v_low
  from public.pantry_items
  where owner_id = v_uid;

  return jsonb_build_object(
    'dinnerChoice', coalesce(v_dinner, 'null'::jsonb),
    'pantrySummary', jsonb_build_object(
      'available', coalesce(v_available, 0),
      'low', coalesce(v_low, 0),
      'trackingStyle', 'loose'
    )
  );
end;
$$;

create or replace function public.rhythm_phase4_action(
  p_action text,
  p_date date,
  p_chunk_id uuid default null,
  p_prompt_id uuid default null,
  p_mood text default null,
  p_note text default null,
  p_effort text default null,
  p_meal_id uuid default null,
  p_pantry_item_id uuid default null
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_base jsonb;
  v_choices jsonb := '[]'::jsonb;
  v_effort text;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  if p_action not in (
    'get_state', 'complete', 'start', 'reset_today',
    'accept_prompt', 'snooze_prompt', 'dismiss_prompt', 'close_out',
    'meal_help', 'select_meal', 'pantry_gone'
  ) then
    raise exception 'Unsupported Phase 4 action: %', p_action using errcode = '22023';
  end if;

  if p_action in ('meal_help', 'select_meal', 'pantry_gone') then
    v_base := public.rhythm_phase5_state(p_date);
  else
    v_base := public.rhythm_phase5_action(
      p_action, p_date, p_chunk_id, p_prompt_id, p_mood, p_note
    );
  end if;

  if p_action = 'select_meal' then
    if p_meal_id is null then
      raise exception 'Choose a meal first.' using errcode = '22023';
    end if;

    if not exists (
      select 1 from public.meals m
      where m.id = p_meal_id and m.owner_id = v_uid and m.active
    ) then
      raise exception 'That meal is not available.' using errcode = '22023';
    end if;

    update public.daily_plans
    set dinner_meal_id = p_meal_id,
        dinner_selected_at = clock_timestamp(),
        updated_at = clock_timestamp()
    where owner_id = v_uid and plan_date = p_date;

    if not found then
      raise exception 'Build today before choosing dinner.' using errcode = '22023';
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
          'id', m.id,
          'title', m.title,
          'effort', m.effort,
          'minutes', m.minutes,
          'instructions', m.instructions,
          'equipment', to_jsonb(m.equipment),
          'supportiveNote', m.supportive_note,
          'ingredients', coalesce((
            select jsonb_agg(jsonb_build_object(
              'key', mi.item_key,
              'name', mi.ingredient_name,
              'required', mi.required
            ) order by mi.created_at)
            from public.meal_ingredients mi
            where mi.meal_id = m.id
          ), '[]'::jsonb)
        ) as choice,
        case when v_effort = 'any' or m.effort = v_effort then 0 else 1 end as rank_order,
        m.sort_order
      from public.meals m
      where m.owner_id = v_uid
        and m.active
        and (v_effort = 'any' or m.effort = v_effort)
        and not exists (
          select 1
          from public.meal_ingredients mi
          where mi.meal_id = m.id
            and mi.required
            and not exists (
              select 1 from public.pantry_items pi
              where pi.owner_id = v_uid
                and pi.item_key = mi.item_key
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
      'mealChoices', case when p_action = 'meal_help' then v_choices else 'null'::jsonb end
    );
end;
$$;

create or replace function public.rhythm_record_grocery_import(
  p_source text,
  p_purchased_on date,
  p_items jsonb,
  p_note text default null
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_import_id uuid;
  v_count integer;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one grocery item is required.' using errcode = '22023';
  end if;

  insert into public.grocery_imports (owner_id, source, purchased_on, item_count, note, item_summary)
  values (
    v_uid,
    left(coalesce(nullif(trim(p_source), ''), 'shopping_upload'), 80),
    coalesce(p_purchased_on, current_date),
    jsonb_array_length(p_items),
    nullif(left(trim(coalesce(p_note, '')), 280), ''),
    p_items
  ) returning id into v_import_id;

  insert into public.pantry_items (
    owner_id, item_key, name, category, stock_status,
    quantity_estimate, unit, source, last_import_id, last_seen_at, updated_at
  )
  select
    v_uid,
    item_key,
    name,
    category,
    coalesce(nullif(stock_status, ''), 'available'),
    quantity_estimate,
    nullif(unit, ''),
    left(coalesce(nullif(trim(p_source), ''), 'shopping_upload'), 80),
    v_import_id,
    clock_timestamp(),
    clock_timestamp()
  from jsonb_to_recordset(p_items) as x(
    item_key text,
    name text,
    category text,
    stock_status text,
    quantity_estimate numeric,
    unit text
  )
  where item_key is not null
    and name is not null
    and category in ('protein', 'grain', 'vegetable', 'fruit', 'breakfast', 'snack', 'drink', 'dessert', 'other')
    and coalesce(nullif(stock_status, ''), 'available') in ('available', 'low', 'gone')
  on conflict (owner_id, item_key) do update
    set name = excluded.name,
        category = excluded.category,
        stock_status = excluded.stock_status,
        quantity_estimate = coalesce(excluded.quantity_estimate, public.pantry_items.quantity_estimate),
        unit = coalesce(excluded.unit, public.pantry_items.unit),
        source = excluded.source,
        last_import_id = excluded.last_import_id,
        last_seen_at = excluded.last_seen_at,
        updated_at = excluded.updated_at;

  get diagnostics v_count = row_count;
  return jsonb_build_object('ok', true, 'importId', v_import_id, 'itemsUpdated', v_count);
end;
$$;

revoke all on function public.rhythm_meal_state(date) from public, anon;
revoke all on function public.rhythm_phase4_action(text, date, uuid, uuid, text, text, text, uuid, uuid) from public, anon;
revoke all on function public.rhythm_record_grocery_import(text, date, jsonb, text) from public, anon;
grant execute on function public.rhythm_meal_state(date) to authenticated;
grant execute on function public.rhythm_phase4_action(text, date, uuid, uuid, text, text, text, uuid, uuid) to authenticated;
grant execute on function public.rhythm_record_grocery_import(text, date, jsonb, text) to authenticated;

-- Personal pantry and meal seeds are intentionally stored only in Supabase, not in source control.
