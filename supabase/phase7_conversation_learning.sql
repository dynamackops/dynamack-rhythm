-- Dynamack Rhythm Phase 7: conversational safe actions and gentle pattern learning.
-- No new tables: conversation is single-turn, and insights are calculated from existing history.

create or replace function public.rhythm_change_energy(
  p_date date,
  p_energy_mode text
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_label text;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  if p_energy_mode not in ('normal', 'low_energy', 'recovery', 'overwhelmed', 'momentum') then
    raise exception 'Unknown energy mode.' using errcode = '22023';
  end if;

  update public.daily_plans
  set energy_mode = p_energy_mode,
      updated_at = clock_timestamp()
  where owner_id = v_uid and plan_date = p_date;

  if not found then
    raise exception 'Build today before changing its energy.' using errcode = '22023';
  end if;

  v_label := case p_energy_mode
    when 'normal' then 'Normal'
    when 'low_energy' then 'Low energy'
    when 'recovery' then 'Recovery'
    when 'overwhelmed' then 'Overwhelmed'
    when 'momentum' then 'Momentum'
  end;

  return public.rhythm_phase6_action('get_state', p_date)
    || jsonb_build_object(
      'action', 'change_energy',
      'agentChange', jsonb_build_object(
        'changed', true,
        'message', 'I changed today to ' || v_label || ' mode.'
      )
    );
end;
$function$;

create or replace function public.rhythm_learning_context(p_days integer default 28)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_days integer := greatest(14, least(coalesce(p_days, 28), 28));
  v_start date := current_date - (greatest(14, least(coalesce(p_days, 28), 28)) - 1);
  v_observed integer := 0;
  v_patterns jsonb := '[]'::jsonb;
  v_aggregates jsonb := '{}'::jsonb;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  select count(*)::integer into v_observed
  from public.day_history dh
  where dh.owner_id = v_uid and dh.plan_date >= v_start;

  with history as (
    select dh.*
    from public.day_history dh
    where dh.owner_id = v_uid and dh.plan_date >= v_start
  ),
  chunk_rows as (
    select
      h.plan_date,
      h.energy_mode,
      item->>'key' as chunk_key,
      item->>'status' as chunk_status,
      coalesce((item->>'easeLevel')::integer, 0) as ease_level
    from history h
    cross join lateral jsonb_array_elements(h.chunk_snapshot) item
  ),
  chunk_summary as (
    select
      chunk_key,
      count(*)::integer as observed_days,
      count(*) filter (where chunk_status = 'completed')::integer as completed_days,
      count(*) filter (where ease_level > 0)::integer as easier_days
    from chunk_rows
    where chunk_key is not null
    group by chunk_key
  ),
  energy_summary as (
    select
      energy_mode,
      count(*)::integer as observed_days,
      sum(completed_count)::integer as completed_chunks,
      sum(unfinished_count)::integer as unfinished_chunks
    from history
    group by energy_mode
  ),
  meal_summary as (
    select
      m.effort,
      count(*)::integer as chosen_days
    from history h
    join public.daily_plans dp
      on dp.id = h.daily_plan_id and dp.owner_id = v_uid
    join public.meals m
      on m.id = dp.dinner_meal_id and m.owner_id = v_uid
    group by m.effort
  ),
  movement_summary as (
    select
      count(*) filter (where dp.movement_option_id is not null)::integer as planned_days,
      count(*) filter (
        where dp.movement_option_id is not null
          and dp.movement_option_id = dp.movement_fallback_option_id
      )::integer as fallback_days
    from history h
    join public.daily_plans dp
      on dp.id = h.daily_plan_id and dp.owner_id = v_uid
  )
  select jsonb_build_object(
    'energyModes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'energyMode', energy_mode,
        'observedDays', observed_days,
        'completedChunks', completed_chunks,
        'unfinishedChunks', unfinished_chunks
      ) order by energy_mode)
      from energy_summary
    ), '[]'::jsonb),
    'chunks', coalesce((
      select jsonb_agg(jsonb_build_object(
        'chunkKey', chunk_key,
        'observedDays', observed_days,
        'completedDays', completed_days,
        'easierDays', easier_days
      ) order by chunk_key)
      from chunk_summary
    ), '[]'::jsonb),
    'mealEffort', coalesce((
      select jsonb_agg(jsonb_build_object(
        'effort', effort,
        'chosenDays', chosen_days
      ) order by chosen_days desc, effort)
      from meal_summary
    ), '[]'::jsonb),
    'movement', coalesce((select to_jsonb(movement_summary) from movement_summary),
      jsonb_build_object('planned_days', 0, 'fallback_days', 0))
  ) into v_aggregates;

  if v_observed >= 3 then
    with history as (
      select dh.*
      from public.day_history dh
      where dh.owner_id = v_uid and dh.plan_date >= v_start
    ),
    chunk_rows as (
      select
        item->>'key' as chunk_key,
        item->>'status' as chunk_status,
        coalesce((item->>'easeLevel')::integer, 0) as ease_level
      from history h
      cross join lateral jsonb_array_elements(h.chunk_snapshot) item
    ),
    chunk_summary as (
      select
        chunk_key,
        count(*)::integer as observed_days,
        count(*) filter (where chunk_status = 'completed')::integer as completed_days,
        count(*) filter (where ease_level > 0)::integer as easier_days
      from chunk_rows
      where chunk_key is not null
      group by chunk_key
    ),
    meal_summary as (
      select m.effort, count(*)::integer as chosen_days
      from history h
      join public.daily_plans dp on dp.id = h.daily_plan_id and dp.owner_id = v_uid
      join public.meals m on m.id = dp.dinner_meal_id and m.owner_id = v_uid
      group by m.effort
    ),
    meal_total as (
      select coalesce(sum(chosen_days), 0)::integer as total from meal_summary
    ),
    movement_summary as (
      select
        count(*) filter (where dp.movement_option_id is not null)::integer as planned_days,
        count(*) filter (
          where dp.movement_option_id is not null
            and dp.movement_option_id = dp.movement_fallback_option_id
        )::integer as fallback_days
      from history h
      join public.daily_plans dp on dp.id = h.daily_plan_id and dp.owner_id = v_uid
    ),
    candidates as (
      select
        'ease_' || chunk_key as pattern_id,
        'easing' as kind,
        jsonb_build_object(
          'chunkKey', chunk_key,
          'easierDays', easier_days,
          'observedDays', observed_days
        ) as evidence
      from chunk_summary
      where observed_days >= 3 and easier_days >= 2

      union all

      select
        'meal_' || ms.effort,
        'meal_effort',
        jsonb_build_object(
          'effort', ms.effort,
          'chosenDays', ms.chosen_days,
          'totalMealDays', mt.total
        )
      from meal_summary ms
      cross join meal_total mt
      where mt.total >= 3
        and ms.chosen_days >= 2
        and ms.chosen_days * 2 >= mt.total

      union all

      select
        'movement_fallback',
        'movement_fallback',
        jsonb_build_object(
          'plannedDays', planned_days,
          'fallbackDays', fallback_days
        )
      from movement_summary
      where planned_days >= 3 and fallback_days >= 2

      union all

      select
        'chunk_support_' || chunk_key,
        'chunk_support',
        jsonb_build_object(
          'chunkKey', chunk_key,
          'completedDays', completed_days,
          'observedDays', observed_days
        )
      from chunk_summary
      where observed_days >= 3
        and completed_days >= 2
        and completed_days * 4 >= observed_days * 3
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', pattern_id,
      'kind', kind,
      'evidence', evidence
    ) order by pattern_id), '[]'::jsonb)
    into v_patterns
    from candidates;
  end if;

  return jsonb_build_object(
    'ok', true,
    'windowDays', v_days,
    'windowStart', v_start,
    'observedDays', v_observed,
    'minimumDays', 3,
    'ready', v_observed >= 3,
    'aggregates', v_aggregates,
    'patterns', v_patterns
  );
end;
$function$;

revoke all on function public.rhythm_change_energy(date, text) from public, anon, service_role;
revoke all on function public.rhythm_learning_context(integer) from public, anon, service_role;
grant execute on function public.rhythm_change_energy(date, text) to authenticated;
grant execute on function public.rhythm_learning_context(integer) to authenticated;

notify pgrst, 'reload schema';
