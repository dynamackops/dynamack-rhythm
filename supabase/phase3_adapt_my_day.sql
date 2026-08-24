-- Rhythm Agent Phase 3: authenticated, minimal-diff day adaptation.
-- AI may suggest only target IDs and gentler wording. Postgres enforces the patch scope.

create or replace function public.rhythm_adapt_context(p_date date)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_plan_id uuid;
  v_result jsonb;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  select dp.id into v_plan_id
  from public.daily_plans dp
  where dp.owner_id = v_uid and dp.plan_date = p_date
  limit 1;

  if v_plan_id is null then
    raise exception 'Build today before adapting it.' using errcode = '22023';
  end if;

  select jsonb_build_object(
    'ok', true,
    'date', p_date::text,
    'planId', dp.id,
    'energyMode', dp.energy_mode,
    'currentMovement', jsonb_build_object(
      'optionId', dp.movement_option_id,
      'optionTitle', selected.title,
      'fallbackOptionId', dp.movement_fallback_option_id,
      'fallbackTitle', fallback.title,
      'intensity', dp.movement_intensity,
      'reason', dp.movement_reason
    ),
    'targets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id,
        'key', c.template_key,
        'title', c.title,
        'status', c.status,
        'position', c.position,
        'transitionCue', c.transition_cue,
        'easeLevel', c.ease_level
      ) order by c.position)
      from public.chunks c
      where c.daily_plan_id = dp.id
        and c.owner_id = v_uid
        and c.status in ('current', 'next')
        and c.ease_level < 3
    ), '[]'::jsonb),
    'easierMovementOptions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', mo.id,
        'key', mo.option_key,
        'title', mo.title,
        'defaultIntensity', mo.default_intensity,
        'isFallback', mo.is_fallback
      ) order by mo.is_fallback desc, mo.title)
      from public.movement_options mo
      where mo.owner_id = v_uid
        and mo.active = true
        and (mo.default_intensity in ('low', 'recovery') or mo.is_fallback = true)
    ), '[]'::jsonb),
    'availableContext', jsonb_build_object(
      'latestCheckinImplemented', false,
      'userNoteProvidedByWorkflow', true
    )
  ) into v_result
  from public.daily_plans dp
  left join public.movement_options selected on selected.id = dp.movement_option_id
  left join public.movement_options fallback on fallback.id = dp.movement_fallback_option_id
  where dp.id = v_plan_id and dp.owner_id = v_uid;

  return v_result;
end;
$function$;

create or replace function public.rhythm_apply_adaptation(
  p_date date,
  p_changes jsonb default '[]'::jsonb,
  p_message text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_plan_id uuid;
  v_item jsonb;
  v_chunk_id uuid;
  v_template_key text;
  v_old_ease smallint;
  v_new_ease smallint;
  v_cue text;
  v_option_id uuid;
  v_option_valid boolean;
  v_intensity text;
  v_changed_ids jsonb := '[]'::jsonb;
  v_changed_count integer := 0;
  v_message text;
  v_state jsonb;
  v_now timestamptz := clock_timestamp();
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  if jsonb_typeof(coalesce(p_changes, '[]'::jsonb)) <> 'array' then
    raise exception 'Adaptation changes must be an array.' using errcode = '22023';
  end if;

  if jsonb_array_length(coalesce(p_changes, '[]'::jsonb)) > 2 then
    raise exception 'Adaptation may change at most NOW and NEXT.' using errcode = '22023';
  end if;

  select dp.id into v_plan_id
  from public.daily_plans dp
  where dp.owner_id = v_uid and dp.plan_date = p_date
  limit 1;

  if v_plan_id is null then
    raise exception 'Build today before adapting it.' using errcode = '22023';
  end if;

  perform c.id
  from public.chunks c
  where c.daily_plan_id = v_plan_id and c.owner_id = v_uid
  order by c.position
  for update;

  for v_item in select value from jsonb_array_elements(coalesce(p_changes, '[]'::jsonb))
  loop
    begin
      v_chunk_id := nullif(v_item->>'chunkId', '')::uuid;
    exception when invalid_text_representation then
      v_chunk_id := null;
    end;

    if v_chunk_id is null or v_changed_ids @> jsonb_build_array(v_chunk_id::text) then
      continue;
    end if;

    select c.template_key, c.ease_level
      into v_template_key, v_old_ease
    from public.chunks c
    where c.id = v_chunk_id
      and c.daily_plan_id = v_plan_id
      and c.owner_id = v_uid
      and c.status in ('current', 'next')
    for update;

    if not found or v_old_ease >= 3 then
      continue;
    end if;

    v_new_ease := least(v_old_ease + 1, 3);
    v_cue := nullif(left(trim(coalesce(v_item->>'transitionCue', '')), 160), '');
    if v_cue is null then
      v_cue := case v_template_key
        when 'morning' then 'Water, meds, and one gentle reset are enough.'
        when 'focus' then 'Choose one tiny starting point. Ten minutes is enough.'
        when 'outside_work' then 'The balcony or courtyard counts. Bring only what you need.'
        when 'movement' then 'Change into gym clothes. Gentle mobility or a short walk counts.'
        when 'evening' then 'Close one loop, then let the rest wait.'
        else 'Do the smallest version that helps.'
      end;
    end if;

    update public.chunks
    set ease_level = v_new_ease,
        transition_cue = v_cue,
        updated_at = v_now
    where id = v_chunk_id and owner_id = v_uid;

    if v_template_key = 'movement' then
      begin
        v_option_id := nullif(v_item->>'movementOptionId', '')::uuid;
      exception when invalid_text_representation then
        v_option_id := null;
      end;

      select exists(
        select 1 from public.movement_options mo
        where mo.id = v_option_id
          and mo.owner_id = v_uid
          and mo.active = true
          and (mo.default_intensity in ('low', 'recovery') or mo.is_fallback = true)
      ) into v_option_valid;

      v_intensity := case
        when v_item->>'movementIntensity' in ('low', 'recovery')
          then v_item->>'movementIntensity'
        when v_new_ease >= 2 then 'recovery'
        else 'low'
      end;

      if not v_option_valid and v_new_ease >= 2 then
        select mo.id into v_option_id
        from public.movement_options mo
        where mo.owner_id = v_uid and mo.active = true and mo.is_fallback = true
        order by mo.title
        limit 1;
        v_option_valid := v_option_id is not null;
      end if;

      update public.daily_plans
      set movement_option_id = case when v_option_valid then v_option_id else movement_option_id end,
          movement_intensity = v_intensity,
          updated_at = v_now
      where id = v_plan_id and owner_id = v_uid;
    end if;

    v_changed_ids := v_changed_ids || jsonb_build_array(v_chunk_id::text);
    v_changed_count := v_changed_count + 1;
  end loop;

  v_message := case
    when v_changed_count = 0 then 'This is already at its gentlest.'
    else coalesce(nullif(left(trim(coalesce(p_message, '')), 160), ''), 'I made the smallest useful change.')
  end;

  v_state := public.rhythm_apply_action('get_state', p_date, null);

  return v_state || jsonb_build_object(
    'action', 'make_easier',
    'adaptation', jsonb_build_object(
      'changed', v_changed_count > 0,
      'changedChunkIds', v_changed_ids,
      'message', v_message
    )
  );
end;
$function$;

revoke all on function public.rhythm_adapt_context(date) from public;
revoke all on function public.rhythm_adapt_context(date) from anon;
revoke all on function public.rhythm_adapt_context(date) from service_role;
grant execute on function public.rhythm_adapt_context(date) to authenticated;

revoke all on function public.rhythm_apply_adaptation(date, jsonb, text) from public;
revoke all on function public.rhythm_apply_adaptation(date, jsonb, text) from anon;
revoke all on function public.rhythm_apply_adaptation(date, jsonb, text) from service_role;
grant execute on function public.rhythm_apply_adaptation(date, jsonb, text) to authenticated;
