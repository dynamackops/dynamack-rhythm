-- Rhythm Agent Phase 1 atomic action RPC.
-- Applied to Supabase project yipznshcsgrqdzbcthjw on 2026-08-23.
-- SECURITY INVOKER keeps existing table RLS in force for every action.

create or replace function public.rhythm_apply_action(
  p_action text,
  p_date date,
  p_chunk_id uuid default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_action text := lower(trim(coalesce(p_action, 'get_state')));
  v_plan_id uuid;
  v_current_id uuid;
  v_next_id uuid;
  v_next_position smallint;
  v_selected_position smallint;
  v_following_id uuid;
  v_total_count integer;
  v_completed_count integer;
  v_now timestamptz := clock_timestamp();
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  if v_action not in ('get_state', 'complete', 'start', 'reset_today') then
    raise exception 'Unsupported Phase 1 action: %', v_action using errcode = '22023';
  end if;

  select dp.id
    into v_plan_id
  from public.daily_plans dp
  where dp.owner_id = v_uid
    and dp.plan_date = p_date
  limit 1;

  if v_plan_id is null then
    return jsonb_build_object(
      'ok', true,
      'action', v_action,
      'date', p_date::text,
      'needsSetup', true,
      'energyMode', 'normal',
      'now', null,
      'next', null,
      'later', '[]'::jsonb,
      'completed', '[]'::jsonb,
      'chunks', '[]'::jsonb
    );
  end if;

  if v_action <> 'get_state' then
    perform c.id
    from public.chunks c
    where c.daily_plan_id = v_plan_id
      and c.owner_id = v_uid
    order by c.position
    for update;
  end if;

  if v_action = 'reset_today' then
    select count(*), count(*) filter (where c.status = 'completed')
      into v_total_count, v_completed_count
    from public.chunks c
    where c.daily_plan_id = v_plan_id
      and c.owner_id = v_uid;

    if v_total_count = 0 or v_completed_count <> v_total_count then
      raise exception 'Today can only be reopened after every chunk is complete.' using errcode = '22023';
    end if;

    with ordered as (
      select c.id, row_number() over (order by c.position) as sequence
      from public.chunks c
      where c.daily_plan_id = v_plan_id
        and c.owner_id = v_uid
    )
    update public.chunks c
    set status = case
          when ordered.sequence = 1 then 'current'
          when ordered.sequence = 2 then 'next'
          else 'later'
        end,
        started_at = case when ordered.sequence = 1 then v_now else null end,
        completed_at = null,
        updated_at = v_now
    from ordered
    where c.id = ordered.id;

    update public.daily_plans
    set status = 'active',
        updated_at = v_now
    where id = v_plan_id
      and owner_id = v_uid;
  elsif v_action = 'complete' then
    select c.id
      into v_current_id
    from public.chunks c
    where c.daily_plan_id = v_plan_id
      and c.owner_id = v_uid
      and c.status = 'current'
    limit 1;

    if v_current_id is null then
      raise exception 'There is no current chunk to complete.' using errcode = '22023';
    end if;

    select c.id, c.position
      into v_next_id, v_next_position
    from public.chunks c
    where c.daily_plan_id = v_plan_id
      and c.owner_id = v_uid
      and c.status = 'next'
    limit 1;

    if v_next_id is not null then
      select c.id
        into v_following_id
      from public.chunks c
      where c.daily_plan_id = v_plan_id
        and c.owner_id = v_uid
        and c.status = 'later'
        and c.position > v_next_position
      order by c.position
      limit 1;
    end if;

    update public.chunks
    set status = 'completed',
        completed_at = v_now,
        updated_at = v_now
    where id = v_current_id
      and owner_id = v_uid;

    if v_next_id is not null then
      update public.chunks
      set status = 'current',
          started_at = coalesce(started_at, v_now),
          updated_at = v_now
      where id = v_next_id
        and owner_id = v_uid;
    end if;

    if v_following_id is not null then
      update public.chunks
      set status = 'next',
          updated_at = v_now
      where id = v_following_id
        and owner_id = v_uid;
    end if;
  elsif v_action = 'start' then
    select c.position
      into v_selected_position
    from public.chunks c
    where c.id = p_chunk_id
      and c.daily_plan_id = v_plan_id
      and c.owner_id = v_uid
      and c.status not in ('completed', 'skipped');

    if v_selected_position is null then
      raise exception 'Select an unfinished chunk to start.' using errcode = '22023';
    end if;

    select c.id
      into v_following_id
    from public.chunks c
    where c.daily_plan_id = v_plan_id
      and c.owner_id = v_uid
      and c.id <> p_chunk_id
      and c.status not in ('completed', 'skipped')
      and c.position > v_selected_position
    order by c.position
    limit 1;

    update public.chunks
    set status = 'later',
        updated_at = v_now
    where daily_plan_id = v_plan_id
      and owner_id = v_uid
      and status in ('current', 'next', 'later');

    update public.chunks
    set status = 'current',
        started_at = coalesce(started_at, v_now),
        updated_at = v_now
    where id = p_chunk_id
      and owner_id = v_uid;

    if v_following_id is not null then
      update public.chunks
      set status = 'next',
          updated_at = v_now
      where id = v_following_id
        and owner_id = v_uid;
    end if;
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
    where c.daily_plan_id = v_plan_id
      and c.owner_id = v_uid
  )
  select jsonb_build_object(
    'ok', true,
    'action', v_action,
    'date', p_date::text,
    'needsSetup', (select count(*) = 0 from visible),
    'energyMode', coalesce((select dp.energy_mode from public.daily_plans dp where dp.id = v_plan_id), 'normal'),
    'now', coalesce((select payload from visible where status = 'current' order by position limit 1), 'null'::jsonb),
    'next', coalesce((select payload from visible where status = 'next' order by position limit 1), 'null'::jsonb),
    'later', coalesce((select jsonb_agg(payload order by position) from visible where status = 'later'), '[]'::jsonb),
    'completed', coalesce((select jsonb_agg(payload order by position) from visible where status = 'completed'), '[]'::jsonb),
    'chunks', coalesce((select jsonb_agg(payload order by position) from visible), '[]'::jsonb)
  )
  into v_result;

  return v_result;
end;
$function$;

revoke all on function public.rhythm_apply_action(text, date, uuid) from public;
revoke all on function public.rhythm_apply_action(text, date, uuid) from anon;
grant execute on function public.rhythm_apply_action(text, date, uuid) to authenticated;
