-- Rhythm Agent Phase 1 reference schema.
-- Applied to Supabase project yipznshcsgrqdzbcthjw on 2026-08-23.

create table public.routine_templates (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  is_default boolean not null default false,
  chunks_json jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint routine_templates_chunks_array check (jsonb_typeof(chunks_json) = 'array')
);

create unique index routine_templates_one_default
  on public.routine_templates (is_default)
  where is_default = true;

create table public.daily_plans (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  plan_date date not null,
  energy_mode text not null default 'normal'
    check (energy_mode in ('normal', 'low_energy', 'recovery', 'overwhelmed', 'momentum')),
  status text not null default 'active'
    check (status in ('active', 'completed', 'reset')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (owner_id, plan_date)
);

create table public.chunks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  daily_plan_id uuid not null references public.daily_plans(id) on delete cascade,
  template_key text not null,
  title text not null,
  position smallint not null check (position > 0),
  status text not null check (status in ('current', 'next', 'later', 'completed', 'skipped')),
  transition_cue text,
  ease_level smallint not null default 0 check (ease_level between 0 and 3),
  started_at timestamptz,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (daily_plan_id, position),
  unique (daily_plan_id, template_key)
);

create unique index chunks_one_current_per_plan on public.chunks (daily_plan_id) where status = 'current';
create unique index chunks_one_next_per_plan on public.chunks (daily_plan_id) where status = 'next';
create index chunks_owner_id_idx on public.chunks (owner_id);

alter table public.routine_templates enable row level security;
alter table public.daily_plans enable row level security;
alter table public.chunks enable row level security;

revoke all on public.routine_templates from anon;
revoke all on public.daily_plans from anon;
revoke all on public.chunks from anon;

grant select on public.routine_templates to authenticated;
grant select, insert, update on public.daily_plans to authenticated;
grant select, insert, update on public.chunks to authenticated;

create policy "authenticated users read default templates"
on public.routine_templates for select to authenticated using (is_default = true);

create policy "owner reads daily plans"
on public.daily_plans for select to authenticated using ((select auth.uid()) = owner_id);

create policy "owner creates daily plans"
on public.daily_plans for insert to authenticated with check ((select auth.uid()) = owner_id);

create policy "owner updates daily plans"
on public.daily_plans for update to authenticated
using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);

create policy "owner reads chunks"
on public.chunks for select to authenticated using ((select auth.uid()) = owner_id);

create policy "owner creates chunks"
on public.chunks for insert to authenticated
with check (
  (select auth.uid()) = owner_id
  and exists (
    select 1 from public.daily_plans p
    where p.id = daily_plan_id and p.owner_id = (select auth.uid())
  )
);

create policy "owner updates chunks"
on public.chunks for update to authenticated
using ((select auth.uid()) = owner_id)
with check (
  (select auth.uid()) = owner_id
  and exists (
    select 1 from public.daily_plans p
    where p.id = daily_plan_id and p.owner_id = (select auth.uid())
  )
);

insert into public.routine_templates (name, is_default, chunks_json)
values (
  'Default Daily Rhythm',
  true,
  '[
    {"key":"morning","title":"Morning","position":1},
    {"key":"focus","title":"Focus","position":2},
    {"key":"outside_work","title":"Outside Work","position":3,"cue":"Change into gym clothes before Movement."},
    {"key":"movement","title":"Movement","position":4},
    {"key":"evening","title":"Evening","position":5}
  ]'::jsonb
);
