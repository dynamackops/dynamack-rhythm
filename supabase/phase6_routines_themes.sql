create table if not exists public.user_preferences (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  theme text not null default 'blush' check (theme in ('blush', 'lavender', 'blue', 'sage', 'dark')),
  lofi_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.routine_step_templates (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  chunk_key text not null check (chunk_key in ('morning', 'outside_work', 'evening')),
  step_key text not null,
  title text not null check (char_length(title) between 1 and 80),
  icon text not null check (char_length(icon) between 1 and 12),
  position smallint not null check (position > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, chunk_key, step_key)
);

create table if not exists public.cleaning_tasks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  task_key text not null,
  title text not null check (char_length(title) between 1 and 80),
  icon text not null check (char_length(icon) between 1 and 12),
  position smallint not null check (position > 0),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, task_key)
);

create table if not exists public.daily_routine_steps (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  daily_plan_id uuid not null references public.daily_plans(id) on delete cascade,
  chunk_key text not null check (chunk_key in ('morning', 'outside_work', 'evening')),
  step_key text not null,
  title text not null check (char_length(title) between 1 and 80),
  icon text not null check (char_length(icon) between 1 and 12),
  position smallint not null check (position > 0),
  status text not null default 'pending' check (status in ('pending', 'completed')),
  source text not null default 'routine' check (source in ('routine', 'cleaning_rotation')),
  routine_template_id uuid references public.routine_step_templates(id) on delete set null,
  cleaning_task_id uuid references public.cleaning_tasks(id) on delete set null,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (daily_plan_id, step_key)
);

create index if not exists routine_step_templates_owner_idx on public.routine_step_templates(owner_id);
create index if not exists cleaning_tasks_owner_idx on public.cleaning_tasks(owner_id);
create index if not exists daily_routine_steps_owner_idx on public.daily_routine_steps(owner_id);
create index if not exists daily_routine_steps_plan_idx on public.daily_routine_steps(daily_plan_id);
create index if not exists daily_routine_steps_template_idx on public.daily_routine_steps(routine_template_id);
create index if not exists daily_routine_steps_cleaning_idx on public.daily_routine_steps(cleaning_task_id);

alter table public.user_preferences enable row level security;
alter table public.routine_step_templates enable row level security;
alter table public.cleaning_tasks enable row level security;
alter table public.daily_routine_steps enable row level security;

create policy "Owners manage their preferences" on public.user_preferences
  for all to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
create policy "Owners manage routine templates" on public.routine_step_templates
  for all to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
create policy "Owners manage cleaning tasks" on public.cleaning_tasks
  for all to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);
create policy "Owners manage daily routine steps" on public.daily_routine_steps
  for all to authenticated
  using ((select auth.uid()) = owner_id)
  with check ((select auth.uid()) = owner_id);

grant select, insert, update, delete on public.user_preferences to authenticated;
grant select, insert, update, delete on public.routine_step_templates to authenticated;
grant select, insert, update, delete on public.cleaning_tasks to authenticated;
grant select, insert, update, delete on public.daily_routine_steps to authenticated;

create or replace function public.rhythm_ensure_daily_routines(p_date date)
returns void
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_plan_id uuid;
  v_clean public.cleaning_tasks%rowtype;
  v_count integer;
  v_pick integer;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  select id into v_plan_id
  from public.daily_plans
  where owner_id = v_uid and plan_date = p_date
  limit 1;

  if v_plan_id is null then return; end if;

  insert into public.daily_routine_steps (
    owner_id, daily_plan_id, chunk_key, step_key, title, icon, position, source, routine_template_id
  )
  select v_uid, v_plan_id, rst.chunk_key, rst.step_key, rst.title, rst.icon, rst.position, 'routine', rst.id
  from public.routine_step_templates rst
  where rst.owner_id = v_uid and rst.active
  on conflict (daily_plan_id, step_key) do nothing;

  if not exists (
    select 1 from public.daily_routine_steps
    where owner_id = v_uid and daily_plan_id = v_plan_id and step_key = 'tiny_clean'
  ) then
    select count(*) into v_count
    from public.cleaning_tasks
    where owner_id = v_uid and active;

    if v_count > 0 then
      v_pick := (extract(doy from p_date)::integer % v_count) + 1;
      select * into v_clean
      from public.cleaning_tasks
      where owner_id = v_uid and active
      order by position, id
      offset (v_pick - 1) limit 1;

      insert into public.daily_routine_steps (
        owner_id, daily_plan_id, chunk_key, step_key, title, icon, position, source, cleaning_task_id
      ) values (
        v_uid, v_plan_id, 'outside_work', 'tiny_clean', v_clean.title, v_clean.icon, 2,
        'cleaning_rotation', v_clean.id
      ) on conflict (daily_plan_id, step_key) do nothing;
    end if;
  end if;
end;
$$;

create or replace function public.rhythm_routine_state(p_date date)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_steps jsonb := '[]'::jsonb;
  v_theme text := 'blush';
  v_lofi boolean := false;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  perform public.rhythm_ensure_daily_routines(p_date);

  select coalesce(up.theme, 'blush'), coalesce(up.lofi_enabled, false)
  into v_theme, v_lofi
  from public.user_preferences up
  where up.owner_id = v_uid;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', drs.id,
    'chunkKey', drs.chunk_key,
    'stepKey', drs.step_key,
    'title', drs.title,
    'icon', drs.icon,
    'position', drs.position,
    'completed', drs.status = 'completed',
    'source', drs.source
  ) order by case drs.chunk_key when 'morning' then 1 when 'outside_work' then 2 else 3 end, drs.position), '[]'::jsonb)
  into v_steps
  from public.daily_routine_steps drs
  join public.daily_plans dp on dp.id = drs.daily_plan_id
  where drs.owner_id = v_uid and dp.owner_id = v_uid and dp.plan_date = p_date;

  return jsonb_build_object(
    'theme', coalesce(v_theme, 'blush'),
    'lofiEnabled', coalesce(v_lofi, false),
    'routineSteps', v_steps
  );
end;
$$;

create or replace function public.rhythm_phase6_action(
  p_action text,
  p_date date,
  p_chunk_id uuid default null,
  p_prompt_id uuid default null,
  p_mood text default null,
  p_note text default null,
  p_effort text default null,
  p_meal_id uuid default null,
  p_pantry_item_id uuid default null,
  p_routine_step_id uuid default null,
  p_theme text default null,
  p_lofi_enabled boolean default null
)
returns jsonb
language plpgsql
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := (select auth.uid());
  v_base jsonb;
  v_plan_id uuid;
  v_current_position smallint;
  v_next public.cleaning_tasks%rowtype;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  if p_action not in (
    'get_state', 'complete', 'start', 'reset_today',
    'accept_prompt', 'snooze_prompt', 'dismiss_prompt', 'close_out',
    'meal_help', 'select_meal', 'pantry_gone',
    'toggle_routine', 'swap_cleaning', 'set_theme', 'set_lofi'
  ) then
    raise exception 'Unsupported Rhythm action: %', p_action using errcode = '22023';
  end if;

  if p_action in ('toggle_routine', 'swap_cleaning', 'set_theme', 'set_lofi') then
    v_base := public.rhythm_phase4_action('get_state', p_date);
  else
    v_base := public.rhythm_phase4_action(
      p_action, p_date, p_chunk_id, p_prompt_id, p_mood, p_note,
      p_effort, p_meal_id, p_pantry_item_id
    );
  end if;

  perform public.rhythm_ensure_daily_routines(p_date);

  select id into v_plan_id
  from public.daily_plans
  where owner_id = v_uid and plan_date = p_date
  limit 1;

  if p_action = 'toggle_routine' then
    if p_routine_step_id is null then
      raise exception 'Choose a routine step first.' using errcode = '22023';
    end if;
    update public.daily_routine_steps
    set status = case when status = 'completed' then 'pending' else 'completed' end,
        completed_at = case when status = 'pending' then clock_timestamp() else null end,
        updated_at = clock_timestamp()
    where id = p_routine_step_id and owner_id = v_uid and daily_plan_id = v_plan_id;
    if not found then raise exception 'That routine step was not found.' using errcode = '22023'; end if;
  elsif p_action = 'swap_cleaning' then
    select ct.position into v_current_position
    from public.daily_routine_steps drs
    join public.cleaning_tasks ct on ct.id = drs.cleaning_task_id and ct.owner_id = v_uid
    where drs.owner_id = v_uid and drs.daily_plan_id = v_plan_id and drs.step_key = 'tiny_clean';

    select * into v_next
    from public.cleaning_tasks
    where owner_id = v_uid and active and position > coalesce(v_current_position, 0)
    order by position, id limit 1;

    if v_next.id is null then
      select * into v_next from public.cleaning_tasks
      where owner_id = v_uid and active order by position, id limit 1;
    end if;

    update public.daily_routine_steps
    set title = v_next.title, icon = v_next.icon, cleaning_task_id = v_next.id,
        status = 'pending', completed_at = null, updated_at = clock_timestamp()
    where owner_id = v_uid and daily_plan_id = v_plan_id and step_key = 'tiny_clean';
  elsif p_action = 'set_theme' then
    if p_theme not in ('blush', 'lavender', 'blue', 'sage', 'dark') then
      raise exception 'Unknown theme.' using errcode = '22023';
    end if;
    insert into public.user_preferences (owner_id, theme, updated_at)
    values (v_uid, p_theme, clock_timestamp())
    on conflict (owner_id) do update set theme = excluded.theme, updated_at = excluded.updated_at;
  elsif p_action = 'set_lofi' then
    if p_lofi_enabled is null then raise exception 'Choose an ambience setting.' using errcode = '22023'; end if;
    insert into public.user_preferences (owner_id, lofi_enabled, updated_at)
    values (v_uid, p_lofi_enabled, clock_timestamp())
    on conflict (owner_id) do update set lofi_enabled = excluded.lofi_enabled, updated_at = excluded.updated_at;
  end if;

  return v_base || public.rhythm_routine_state(p_date) || jsonb_build_object('action', p_action);
end;
$$;

revoke all on function public.rhythm_ensure_daily_routines(date) from public, anon;
revoke all on function public.rhythm_routine_state(date) from public, anon;
revoke all on function public.rhythm_phase6_action(text,date,uuid,uuid,text,text,text,uuid,uuid,uuid,text,boolean) from public, anon;
grant execute on function public.rhythm_ensure_daily_routines(date) to authenticated, service_role;
grant execute on function public.rhythm_routine_state(date) to authenticated, service_role;
grant execute on function public.rhythm_phase6_action(text,date,uuid,uuid,text,text,text,uuid,uuid,uuid,text,boolean) to authenticated, service_role;
