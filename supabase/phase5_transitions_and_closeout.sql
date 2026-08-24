-- Rhythm Agent Phase 5: gentle transition suggestions and end-of-day history.
-- Scheduled checks only surface prompts. They never advance a chunk automatically.

create table if not exists public.rhythm_prompts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  daily_plan_id uuid not null references public.daily_plans(id) on delete cascade,
  target_chunk_id uuid references public.chunks(id) on delete cascade,
  prompt_key text not null,
  prompt_type text not null check (prompt_type in ('transition', 'preparation', 'bridge', 'close_out')),
  title text not null,
  message text not null,
  due_at timestamptz not null,
  expires_at timestamptz not null,
  status text not null default 'pending'
    check (status in ('pending', 'surfaced', 'snoozed', 'accepted', 'dismissed', 'expired')),
  surfaced_at timestamptz,
  snoozed_until timestamptz,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (daily_plan_id, prompt_key),
  check (expires_at > due_at)
);

create index if not exists rhythm_prompts_owner_due_idx
  on public.rhythm_prompts (owner_id, due_at, status);
create index if not exists rhythm_prompts_plan_idx
  on public.rhythm_prompts (daily_plan_id);
create index if not exists rhythm_prompts_target_chunk_idx
  on public.rhythm_prompts (target_chunk_id)
  where target_chunk_id is not null;

create table if not exists public.checkins (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  daily_plan_id uuid not null references public.daily_plans(id) on delete cascade,
  checkin_type text not null default 'close_out' check (checkin_type = 'close_out'),
  mood text not null check (mood in ('good', 'meh', 'hard')),
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (daily_plan_id, checkin_type),
  check (note is null or char_length(note) <= 280)
);

create index if not exists checkins_owner_created_idx
  on public.checkins (owner_id, created_at desc);

create table if not exists public.day_history (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  daily_plan_id uuid not null unique references public.daily_plans(id) on delete cascade,
  plan_date date not null,
  energy_mode text not null,
  mood text not null check (mood in ('good', 'meh', 'hard')),
  note text,
  chunk_snapshot jsonb not null check (jsonb_typeof(chunk_snapshot) = 'array'),
  completed_count smallint not null default 0 check (completed_count >= 0),
  unfinished_count smallint not null default 0 check (unfinished_count >= 0),
  closed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, plan_date),
  check (note is null or char_length(note) <= 280)
);

create index if not exists day_history_owner_date_idx
  on public.day_history (owner_id, plan_date desc);

alter table public.rhythm_prompts enable row level security;
alter table public.checkins enable row level security;
alter table public.day_history enable row level security;

drop policy if exists "Owners can view their rhythm prompts" on public.rhythm_prompts;
create policy "Owners can view their rhythm prompts"
on public.rhythm_prompts for select
to authenticated
using ((select auth.uid()) = owner_id);

drop policy if exists "Owners can update their rhythm prompts" on public.rhythm_prompts;
create policy "Owners can update their rhythm prompts"
on public.rhythm_prompts for update
to authenticated
using ((select auth.uid()) = owner_id)
with check ((select auth.uid()) = owner_id);

drop policy if exists "Owners can view their checkins" on public.checkins;
create policy "Owners can view their checkins"
on public.checkins for select
to authenticated
using ((select auth.uid()) = owner_id);

drop policy if exists "Owners can create their checkins" on public.checkins;
create policy "Owners can create their checkins"
on public.checkins for insert
to authenticated
with check ((select auth.uid()) = owner_id);

drop policy if exists "Owners can update their checkins" on public.checkins;
create policy "Owners can update their checkins"
on public.checkins for update
to authenticated
using ((select auth.uid()) = owner_id)
with check ((select auth.uid()) = owner_id);

drop policy if exists "Owners can view their day history" on public.day_history;
create policy "Owners can view their day history"
on public.day_history for select
to authenticated
using ((select auth.uid()) = owner_id);

drop policy if exists "Owners can create their day history" on public.day_history;
create policy "Owners can create their day history"
on public.day_history for insert
to authenticated
with check ((select auth.uid()) = owner_id);

drop policy if exists "Owners can update their day history" on public.day_history;
create policy "Owners can update their day history"
on public.day_history for update
to authenticated
using ((select auth.uid()) = owner_id)
with check ((select auth.uid()) = owner_id);

revoke all on table public.rhythm_prompts, public.checkins, public.day_history from anon;
grant select, update on table public.rhythm_prompts to authenticated;
grant select, insert, update on table public.checkins, public.day_history to authenticated;
grant select, insert, update, delete on table public.rhythm_prompts, public.checkins, public.day_history to service_role;

create or replace function public.rhythm_seed_plan_prompts(
  p_owner_id uuid,
  p_date date
)
returns integer
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_plan_id uuid;
  v_inserted integer := 0;
begin
  if p_owner_id is null then
    return 0;
  end if;

  select dp.id into v_plan_id
  from public.daily_plans dp
  where dp.owner_id = p_owner_id
    and dp.plan_date = p_date
    and dp.status = 'active'
  limit 1;

  if v_plan_id is null then
    return 0;
  end if;

  insert into public.rhythm_prompts (
    owner_id, daily_plan_id, target_chunk_id, prompt_key, prompt_type,
    title, message, due_at, expires_at
  )
  select
    p_owner_id,
    v_plan_id,
    c.id,
    schedule.prompt_key,
    schedule.prompt_type,
    schedule.title,
    schedule.message,
    ((p_date + schedule.due_time) at time zone 'America/New_York'),
    ((p_date + schedule.expires_time) at time zone 'America/New_York')
  from (
    values
      ('focus', 'transition', 'Focus is next', 'Your Focus rhythm is ready when you are.', time '09:00', time '13:00', 'focus'),
      ('outside_work', 'transition', 'Outside Work is next', 'Pool, balcony, or courtyard all count.', time '13:00', time '16:00', 'outside_work'),
      ('prepare_movement', 'preparation', 'Get ready & relax', 'Change into gym clothes, then relax. Movement begins around 5.', time '16:00', time '17:00', 'movement'),
      ('movement', 'transition', 'Movement is next', 'Start the version that fits your energy today.', time '17:00', time '18:00', 'movement'),
      ('dinner_bridge', 'bridge', 'Dinner bridge', 'Dinner is 6–7 PM. Keeping it simple counts.', time '18:00', time '19:00', null),
      ('evening', 'transition', 'Evening is next', 'The day can begin getting quieter now.', time '19:00', time '23:00', 'evening'),
      ('close_out', 'close_out', 'Close out the day?', 'A tiny reflection is enough. Nothing unfinished becomes overdue.', time '21:00', time '23:59:59', null)
  ) as schedule(prompt_key, prompt_type, title, message, due_time, expires_time, target_key)
  left join public.chunks c
    on c.daily_plan_id = v_plan_id
   and c.owner_id = p_owner_id
   and c.template_key = schedule.target_key
  on conflict (daily_plan_id, prompt_key) do nothing;

  get diagnostics v_inserted = row_count;
  return v_inserted;
end;
$function$;

create or replace function public.rhythm_surface_due_prompts(
  p_owner_email text,
  p_now timestamptz default clock_timestamp()
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid;
  v_date date := (p_now at time zone 'America/New_York')::date;
  v_prompt_id uuid;
  v_seeded integer;
begin
  if coalesce((select auth.role()), '') <> 'service_role' then
    raise exception 'The scheduled transition check requires the service role.' using errcode = '42501';
  end if;

  v_uid := public.rhythm_resolve_scheduled_owner(p_owner_email);
  if v_uid is null then
    raise exception 'The scheduled Rhythm owner could not be resolved.' using errcode = '42501';
  end if;

  v_seeded := public.rhythm_seed_plan_prompts(v_uid, v_date);

  update public.rhythm_prompts rp
  set status = 'expired', resolved_at = p_now, updated_at = p_now
  where rp.owner_id = v_uid
    and rp.status in ('pending', 'surfaced', 'snoozed')
    and (
      rp.expires_at <= p_now
      or exists (
        select 1 from public.chunks c
        where c.id = rp.target_chunk_id
          and c.status in ('completed', 'skipped')
      )
      or (
        rp.prompt_type = 'transition'
        and exists (
          select 1 from public.chunks c
          where c.id = rp.target_chunk_id and c.status = 'current'
        )
      )
    );

  -- The 9 PM close-out offer supersedes an older transition card, but still
  -- does not alter the current chunk or close the day automatically.
  if exists (
    select 1 from public.rhythm_prompts rp
    where rp.owner_id = v_uid
      and rp.prompt_type = 'close_out'
      and rp.due_at <= p_now
      and rp.expires_at > p_now
      and rp.status in ('pending', 'snoozed')
  ) then
    update public.rhythm_prompts rp
    set status = 'expired', resolved_at = p_now, updated_at = p_now
    where rp.owner_id = v_uid
      and rp.prompt_type <> 'close_out'
      and rp.status = 'surfaced';
  end if;

  select rp.id into v_prompt_id
  from public.rhythm_prompts rp
  where rp.owner_id = v_uid
    and rp.due_at <= p_now
    and rp.expires_at > p_now
    and (
      rp.status = 'pending'
      or (rp.status = 'snoozed' and rp.snoozed_until <= p_now)
    )
    and not exists (
      select 1 from public.rhythm_prompts active_prompt
      where active_prompt.owner_id = v_uid
        and active_prompt.daily_plan_id = rp.daily_plan_id
        and active_prompt.status = 'surfaced'
    )
  order by (rp.prompt_type = 'close_out') desc, rp.due_at
  limit 1
  for update skip locked;

  if v_prompt_id is not null then
    update public.rhythm_prompts
    set status = 'surfaced',
        surfaced_at = coalesce(surfaced_at, p_now),
        snoozed_until = null,
        updated_at = p_now
    where id = v_prompt_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'action', 'surface_due_prompts',
    'date', v_date::text,
    'seeded', v_seeded,
    'surfacedPromptId', v_prompt_id,
    'checkedAt', p_now
  );
end;
$function$;

create or replace function public.rhythm_phase5_state(p_date date)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_plan_id uuid;
  v_base jsonb;
  v_prompt jsonb;
  v_history jsonb;
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  v_base := public.rhythm_apply_action('get_state', p_date, null);

  select dp.id into v_plan_id
  from public.daily_plans dp
  where dp.owner_id = v_uid and dp.plan_date = p_date
  limit 1;

  if v_plan_id is not null then
    select jsonb_build_object(
      'id', rp.id,
      'type', rp.prompt_type,
      'title', rp.title,
      'message', rp.message,
      'targetChunkId', rp.target_chunk_id,
      'dueAt', rp.due_at,
      'status', rp.status
    ) into v_prompt
    from public.rhythm_prompts rp
    where rp.owner_id = v_uid
      and rp.daily_plan_id = v_plan_id
      and rp.status = 'surfaced'
    order by rp.due_at desc
    limit 1;

    select jsonb_build_object(
      'mood', dh.mood,
      'note', dh.note,
      'completedCount', dh.completed_count,
      'unfinishedCount', dh.unfinished_count,
      'closedAt', dh.closed_at
    ) into v_history
    from public.day_history dh
    where dh.owner_id = v_uid and dh.daily_plan_id = v_plan_id;
  end if;

  return v_base || jsonb_build_object(
    'transitionPrompt', coalesce(v_prompt, 'null'::jsonb),
    'closeOut', jsonb_build_object(
      'label', 'Close out the day',
      'available', v_plan_id is not null and v_history is null,
      'offered', coalesce(v_prompt->>'type', '') = 'close_out',
      'closed', v_history is not null
    ),
    'dayHistory', coalesce(v_history, 'null'::jsonb),
    'schedule', jsonb_build_object(
      'morning', '7–9 AM',
      'focus', '9 AM–1 PM',
      'outside_work', '1–4 PM',
      'prepare_movement', '4–5 PM',
      'movement', '5–6 PM',
      'dinner', '6–7 PM',
      'evening', '7–11 PM',
      'close_out_offer', '9 PM'
    )
  );
end;
$function$;

create or replace function public.rhythm_phase5_action(
  p_action text,
  p_date date,
  p_chunk_id uuid default null,
  p_prompt_id uuid default null,
  p_mood text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public, pg_temp
as $function$
declare
  v_uid uuid := (select auth.uid());
  v_plan_id uuid;
  v_prompt public.rhythm_prompts%rowtype;
  v_now timestamptz := clock_timestamp();
  v_base jsonb;
  v_snapshot jsonb;
  v_completed smallint;
  v_unfinished smallint;
  v_note text := nullif(left(trim(coalesce(p_note, '')), 280), '');
begin
  if v_uid is null then
    raise exception 'A Supabase user session is required.' using errcode = '42501';
  end if;

  if p_action not in (
    'get_state', 'complete', 'start', 'reset_today',
    'accept_prompt', 'snooze_prompt', 'dismiss_prompt', 'close_out'
  ) then
    raise exception 'Unsupported Phase 5 action: %', p_action using errcode = '22023';
  end if;

  select dp.id into v_plan_id
  from public.daily_plans dp
  where dp.owner_id = v_uid and dp.plan_date = p_date
  limit 1;

  if v_plan_id is null then
    return public.rhythm_phase5_state(p_date);
  end if;

  if p_action in ('get_state', 'complete', 'start', 'reset_today') then
    v_base := public.rhythm_apply_action(p_action, p_date, p_chunk_id);

    if p_action in ('complete', 'start') then
      update public.rhythm_prompts rp
      set status = 'accepted', resolved_at = v_now, updated_at = v_now
      where rp.owner_id = v_uid
        and rp.daily_plan_id = v_plan_id
        and rp.status in ('pending', 'surfaced', 'snoozed')
        and (
          (p_action = 'start' and rp.target_chunk_id = p_chunk_id)
          or (
            p_action = 'complete'
            and exists (
              select 1 from public.chunks c
              where c.id = rp.target_chunk_id and c.status = 'current'
            )
          )
        );
    end if;

  elsif p_action in ('accept_prompt', 'snooze_prompt', 'dismiss_prompt') then
    select rp.* into v_prompt
    from public.rhythm_prompts rp
    where rp.id = p_prompt_id
      and rp.owner_id = v_uid
      and rp.daily_plan_id = v_plan_id
      and rp.status in ('surfaced', 'snoozed')
    for update;

    if not found then
      raise exception 'That transition suggestion is no longer active.' using errcode = '22023';
    end if;

    if p_action = 'snooze_prompt' then
      update public.rhythm_prompts
      set status = 'snoozed', snoozed_until = v_now + interval '15 minutes', updated_at = v_now
      where id = v_prompt.id;
    elsif p_action = 'dismiss_prompt' then
      update public.rhythm_prompts
      set status = 'dismissed', resolved_at = v_now, updated_at = v_now
      where id = v_prompt.id;
    else
      update public.rhythm_prompts
      set status = 'accepted', resolved_at = v_now, updated_at = v_now
      where id = v_prompt.id;

      if v_prompt.prompt_type = 'transition' and v_prompt.target_chunk_id is not null then
        v_base := public.rhythm_apply_action('start', p_date, v_prompt.target_chunk_id);
      end if;
    end if;

  elsif p_action = 'close_out' then
    if p_mood not in ('good', 'meh', 'hard') then
      raise exception 'Choose Good, Meh, or Hard to close out the day.' using errcode = '22023';
    end if;

    if exists (
      select 1 from public.day_history dh
      where dh.daily_plan_id = v_plan_id and dh.owner_id = v_uid
    ) then
      return public.rhythm_phase5_state(p_date) || jsonb_build_object('action', p_action);
    end if;

    perform dp.id
    from public.daily_plans dp
    where dp.id = v_plan_id and dp.owner_id = v_uid
    for update;

    select
      coalesce(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'key', c.template_key,
        'title', c.title,
        'position', c.position,
        'status', c.status,
        'easeLevel', c.ease_level,
        'transitionCue', c.transition_cue,
        'startedAt', c.started_at,
        'completedAt', c.completed_at
      ) order by c.position), '[]'::jsonb),
      count(*) filter (where c.status = 'completed')::smallint,
      count(*) filter (where c.status not in ('completed', 'skipped'))::smallint
    into v_snapshot, v_completed, v_unfinished
    from public.chunks c
    where c.daily_plan_id = v_plan_id and c.owner_id = v_uid;

    insert into public.checkins (
      owner_id, daily_plan_id, checkin_type, mood, note, updated_at
    ) values (
      v_uid, v_plan_id, 'close_out', p_mood, v_note, v_now
    )
    on conflict (daily_plan_id, checkin_type) do update
      set mood = excluded.mood, note = excluded.note, updated_at = excluded.updated_at;

    insert into public.day_history (
      owner_id, daily_plan_id, plan_date, energy_mode, mood, note,
      chunk_snapshot, completed_count, unfinished_count, closed_at, updated_at
    )
    select
      v_uid, dp.id, dp.plan_date, dp.energy_mode, p_mood, v_note,
      v_snapshot, v_completed, v_unfinished, v_now, v_now
    from public.daily_plans dp
    where dp.id = v_plan_id and dp.owner_id = v_uid
    on conflict (daily_plan_id) do update
      set mood = excluded.mood,
          note = excluded.note,
          chunk_snapshot = excluded.chunk_snapshot,
          completed_count = excluded.completed_count,
          unfinished_count = excluded.unfinished_count,
          closed_at = excluded.closed_at,
          updated_at = excluded.updated_at;

    update public.chunks
    set status = 'skipped', updated_at = v_now
    where daily_plan_id = v_plan_id
      and owner_id = v_uid
      and status in ('current', 'next', 'later');

    update public.daily_plans
    set status = 'completed', updated_at = v_now
    where id = v_plan_id and owner_id = v_uid;

    update public.rhythm_prompts
    set status = case when prompt_type = 'close_out' then 'accepted' else 'expired' end,
        resolved_at = v_now,
        updated_at = v_now
    where daily_plan_id = v_plan_id
      and owner_id = v_uid
      and status in ('pending', 'surfaced', 'snoozed');
  end if;

  return public.rhythm_phase5_state(p_date) || jsonb_build_object('action', p_action);
end;
$function$;

revoke execute on function public.rhythm_seed_plan_prompts(uuid, date) from public, anon;
revoke execute on function public.rhythm_surface_due_prompts(text, timestamptz) from public, anon, authenticated;
revoke execute on function public.rhythm_phase5_state(date) from public, anon, service_role;
revoke execute on function public.rhythm_phase5_action(text, date, uuid, uuid, text, text) from public, anon, service_role;

grant execute on function public.rhythm_seed_plan_prompts(uuid, date) to authenticated, service_role;
grant execute on function public.rhythm_surface_due_prompts(text, timestamptz) to service_role;
grant execute on function public.rhythm_phase5_state(date) to authenticated;
grant execute on function public.rhythm_phase5_action(text, date, uuid, uuid, text, text) to authenticated;

notify pgrst, 'reload schema';
