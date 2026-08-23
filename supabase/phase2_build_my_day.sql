-- Rhythm Agent Phase 2: movement context and duplicate-safe day building.

create table public.movement_options (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  option_key text not null,
  title text not null,
  category text not null check (category in ('pilates', 'aerial', 'walk', 'swim', 'skate', 'strength', 'mobility')),
  default_intensity text not null default 'normal' check (default_intensity in ('normal', 'low', 'recovery')),
  is_fallback boolean not null default false,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, option_key)
);

create index movement_options_owner_active_idx
  on public.movement_options (owner_id, active);

alter table public.movement_options enable row level security;
revoke all on public.movement_options from anon;
grant select on public.movement_options to authenticated;

create policy "owner reads movement options"
on public.movement_options for select to authenticated
using ((select auth.uid()) = owner_id);

alter table public.daily_plans
  add column movement_option_id uuid references public.movement_options(id) on delete set null,
  add column movement_fallback_option_id uuid references public.movement_options(id) on delete set null,
  add column movement_intensity text check (movement_intensity in ('normal', 'low', 'recovery')),
  add column movement_reason text,
  add column build_source text not null default 'phase1' check (build_source in ('phase1', 'dashboard', 'schedule')),
  add column build_notes jsonb not null default '[]'::jsonb check (jsonb_typeof(build_notes) = 'array'),
  add column built_at timestamptz;

create index daily_plans_movement_option_idx
  on public.daily_plans (movement_option_id);

create index daily_plans_movement_fallback_option_idx
  on public.daily_plans (movement_fallback_option_id);

-- The scheduled workflow receives only the minimum table privileges it needs.
grant select on public.routine_templates, public.movement_options to service_role;
grant select, insert, update on public.daily_plans, public.chunks to service_role;

insert into public.movement_options (
  owner_id, option_key, title, category, default_intensity, is_fallback
)
select
  u.id,
  seed.option_key,
  seed.title,
  seed.category,
  seed.default_intensity,
  seed.is_fallback
from auth.users u
cross join (
  values
    ('pilates', 'Pilates', 'pilates', 'normal', false),
    ('aerial_hammock', 'Aerial hammock', 'aerial', 'normal', false),
    ('walk_luna', 'Walk Luna', 'walk', 'low', false),
    ('swim_pool', 'Swim or pool', 'swim', 'normal', false),
    ('skating', 'Skating', 'skate', 'normal', false),
    ('gym_strength', 'Gym strength', 'strength', 'normal', false),
    ('gentle_mobility', 'Gentle mobility', 'mobility', 'recovery', true)
) as seed(option_key, title, category, default_intensity, is_fallback)
where lower(u.email) = lower('__RHYTHM_OWNER_EMAIL__')
on conflict (owner_id, option_key) do nothing;

create or replace function public.rhythm_resolve_scheduled_owner(
  p_owner_email text
)
returns uuid
language sql
security definer
set search_path = public, pg_temp
as $function$
  select u.id
  from auth.users u
  where lower(u.email) = lower('__RHYTHM_OWNER_EMAIL__')
    and lower(coalesce(p_owner_email, '')) = lower('__RHYTHM_OWNER_EMAIL__')
  limit 1;
$function$;

revoke all on function public.rhythm_resolve_scheduled_owner(text) from public;
revoke all on function public.rhythm_resolve_scheduled_owner(text) from anon;
revoke all on function public.rhythm_resolve_scheduled_owner(text) from authenticated;
grant execute on function public.rhythm_resolve_scheduled_owner(text) to service_role;

create or replace function public.rhythm_build_context(
  p_date date,
  p_owner_email text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_role text := coalesce((select auth.role()), '');
  v_plan_id uuid;
  v_result jsonb;
begin
  if v_uid is null and v_role = 'service_role' then
    v_uid := public.rhythm_resolve_scheduled_owner(p_owner_email);
  end if;

  if v_uid is null then
    raise exception 'A Supabase user session or scheduled owner is required.' using errcode = '42501';
  end if;

  select dp.id into v_plan_id
  from public.daily_plans dp
  where dp.owner_id = v_uid and dp.plan_date = p_date
  limit 1;

  select jsonb_build_object(
    'ok', true,
    'date', p_date::text,
    'ownerId', v_uid,
    'needsBuild', v_plan_id is null,
    'existingPlanId', v_plan_id,
    'energyMode', coalesce((
      select dp.energy_mode from public.daily_plans dp where dp.id = v_plan_id
    ), 'normal'),
    'template', coalesce((
      select rt.chunks_json from public.routine_templates rt
      where rt.is_default = true limit 1
    ), '[]'::jsonb),
    'movementOptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', mo.id,
        'key', mo.option_key,
        'title', mo.title,
        'category', mo.category,
        'defaultIntensity', mo.default_intensity,
        'isFallback', mo.is_fallback
      ) order by mo.title)
      from public.movement_options mo
      where mo.owner_id = v_uid and mo.active = true
    ), '[]'::jsonb),
    'availableContext', jsonb_build_object(
      'mealsImplemented', false,
      'pantryImplemented', false,
      'latestCheckinImplemented', false
    )
  ) into v_result;

  return v_result;
end;
$function$;

create or replace function public.rhythm_build_day(
  p_date date,
  p_selection jsonb default '{}'::jsonb,
  p_source text default 'dashboard',
  p_owner_email text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_role text := coalesce((select auth.role()), '');
  v_plan_id uuid;
  v_template jsonb;
  v_option_id uuid;
  v_fallback_id uuid;
  v_intensity text;
  v_reason text;
  v_notes jsonb;
  v_now timestamptz := clock_timestamp();
  v_created boolean := false;
  v_result jsonb;
begin
  if v_uid is null and v_role = 'service_role' then
    v_uid := public.rhythm_resolve_scheduled_owner(p_owner_email);
  end if;

  if v_uid is null then
    raise exception 'A Supabase user session or scheduled owner is required.' using errcode = '42501';
  end if;

  if p_source not in ('dashboard', 'schedule') then
    raise exception 'Unsupported build source.' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_uid::text || ':' || p_date::text, 0));

  select dp.id into v_plan_id
  from public.daily_plans dp
  where dp.owner_id = v_uid and dp.plan_date = p_date
  limit 1;

  if v_plan_id is null then
    select rt.chunks_json into v_template
    from public.routine_templates rt
    where rt.is_default = true
    limit 1;

    if v_template is null or jsonb_array_length(v_template) <> 5 then
      raise exception 'The default five-chunk routine template is unavailable.' using errcode = '22023';
    end if;

    begin
      v_option_id := nullif(p_selection->>'movementOptionId', '')::uuid;
    exception when invalid_text_representation then
      v_option_id := null;
    end;

    begin
      v_fallback_id := nullif(p_selection->>'movementFallbackOptionId', '')::uuid;
    exception when invalid_text_representation then
      v_fallback_id := null;
    end;

    if not exists (
      select 1 from public.movement_options mo
      where mo.id = v_option_id and mo.owner_id = v_uid and mo.active = true
    ) then
      v_option_id := null;
    end if;

    if not exists (
      select 1 from public.movement_options mo
      where mo.id = v_fallback_id and mo.owner_id = v_uid and mo.active = true
    ) then
      v_fallback_id := null;
    end if;

    v_intensity := case
      when p_selection->>'movementIntensity' in ('normal', 'low', 'recovery')
        then p_selection->>'movementIntensity'
      else null
    end;
    v_reason := nullif(left(trim(coalesce(p_selection->>'movementReason', '')), 240), '');
    v_notes := case
      when jsonb_typeof(p_selection->'notes') = 'array' then p_selection->'notes'
      else '[]'::jsonb
    end;

    insert into public.daily_plans (
      owner_id,
      plan_date,
      energy_mode,
      status,
      movement_option_id,
      movement_fallback_option_id,
      movement_intensity,
      movement_reason,
      build_source,
      build_notes,
      built_at
    ) values (
      v_uid,
      p_date,
      'normal',
      'active',
      v_option_id,
      v_fallback_id,
      v_intensity,
      v_reason,
      p_source,
      v_notes,
      v_now
    )
    returning id into v_plan_id;

    insert into public.chunks (
      owner_id,
      daily_plan_id,
      template_key,
      title,
      position,
      status,
      transition_cue,
      started_at
    )
    select
      v_uid,
      v_plan_id,
      item->>'key',
      item->>'title',
      (item->>'position')::smallint,
      case
        when (item->>'position')::smallint = 1 then 'current'
        when (item->>'position')::smallint = 2 then 'next'
        else 'later'
      end,
      nullif(item->>'cue', ''),
      case when (item->>'position')::smallint = 1 then v_now else null end
    from jsonb_array_elements(v_template) item;

    v_created := true;
  end if;

  with visible as (
    select
      c.position,
      c.status,
      jsonb_build_object(
        'id', c.id,
        'daily_plan_id', c.daily_plan_id,
        'template_key', c.template_key,
        'title', c.title,
        'position', c.position,
        'status', c.status,
        'transition_cue', c.transition_cue,
        'ease_level', c.ease_level,
        'started_at', c.started_at,
        'completed_at', c.completed_at
      ) as payload
    from public.chunks c
    where c.daily_plan_id = v_plan_id and c.owner_id = v_uid
  )
  select jsonb_build_object(
    'ok', true,
    'action', 'make_day',
    'created', v_created,
    'date', p_date::text,
    'needsSetup', false,
    'energyMode', dp.energy_mode,
    'movement', jsonb_build_object(
      'optionId', dp.movement_option_id,
      'optionTitle', selected.title,
      'fallbackOptionId', dp.movement_fallback_option_id,
      'fallbackTitle', fallback.title,
      'intensity', dp.movement_intensity,
      'reason', dp.movement_reason
    ),
    'now', coalesce((select payload from visible where status = 'current' order by position limit 1), 'null'::jsonb),
    'next', coalesce((select payload from visible where status = 'next' order by position limit 1), 'null'::jsonb),
    'later', coalesce((select jsonb_agg(payload order by position) from visible where status = 'later'), '[]'::jsonb),
    'completed', coalesce((select jsonb_agg(payload order by position) from visible where status = 'completed'), '[]'::jsonb),
    'chunks', coalesce((select jsonb_agg(payload order by position) from visible), '[]'::jsonb)
  ) into v_result
  from public.daily_plans dp
  left join public.movement_options selected on selected.id = dp.movement_option_id
  left join public.movement_options fallback on fallback.id = dp.movement_fallback_option_id
  where dp.id = v_plan_id and dp.owner_id = v_uid;

  return v_result;
end;
$function$;

revoke all on function public.rhythm_build_context(date, text) from public;
revoke all on function public.rhythm_build_context(date, text) from anon;
grant execute on function public.rhythm_build_context(date, text) to authenticated, service_role;

revoke all on function public.rhythm_build_day(date, jsonb, text, text) from public;
revoke all on function public.rhythm_build_day(date, jsonb, text, text) from anon;
grant execute on function public.rhythm_build_day(date, jsonb, text, text) to authenticated, service_role;
