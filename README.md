# Rhythm Agent

Rhythm Agent is a neurodivergent-friendly visual daily rhythm system. It makes the invisible visible by emphasizing **NOW**, showing only one **NEXT**, and keeping **LATER** small.

## Phase 1

Phase 1 proves the persistent dashboard-state loop without AI:

- passwordless, single-user Supabase session
- a five-chunk daily rhythm: Morning, Focus, Outside Work, Movement, Evening
- large TV-friendly and responsive phone/laptop dashboard
- live NOW / NEXT / LATER state
- complete the current chunk
- manually start an unfinished chunk
- persistent state in Supabase
- deterministic action routing in n8n

## Phase 2

Phase 2 adds a duplicate-safe daily-plan builder while preserving the fixed five-chunk rhythm:

- builds the day automatically at 6:00 AM Eastern
- lets the dashboard create a missing day with one “Start my day” action
- uses OpenAI only to judge optional movement details
- keeps Morning, Focus, Outside Work, Movement, and Evening deterministic
- validates AI output before an atomic Supabase write
- skips AI when a plan already exists
- falls back safely when AI output is absent or malformed
- stores movement choices from a small personal library

## Phase 3

Phase 3 adds the defining **“Make this easier”** interaction:

- adapts only NOW and, when useful, NEXT
- never changes chunk titles, order, status, or completed chunks
- raises ease by exactly one level per click
- permits at most two patched chunks
- validates all AI IDs and movement choices against live Supabase context
- falls back to deterministic, shame-free cues if AI output is malformed
- immediately returns the revised NOW / NEXT / LATER state

## Architecture

- `index.html`, `styles.css`, and `app.js`: visual dashboard
- Supabase project `Rhythm Agent`: `routine_templates`, `daily_plans`, and `chunks`
- n8n workflow `Rhythm Agent Router — Phase 2`: authenticated `get_state`, `complete`, `start`, `reset_today`, and `make_day` actions
- n8n workflow `Rhythm Agent — Build My Day`: scheduled and authenticated daily-plan builder
- n8n workflow `Rhythm Agent — Adapt My Day`: authenticated, changes-only easing workflow
- `config.js`: browser-safe runtime settings; contains no email address or secret key
- `config.example.js`: reusable configuration template
- `supabase/phase1_schema.sql`: reproducible Phase 1 database definition
- `supabase/phase2_build_my_day.sql`: movement library and duplicate-safe plan builder
- `supabase/phase2_dashboard_state.sql`: Phase 2 dashboard-state response
- `supabase/phase3_adapt_my_day.sql`: adaptation context and atomic minimal-patch RPC
- `n8n/rhythm-router.ts`: validated Workflow SDK source
- `n8n/rhythm-build-my-day.ts`: validated Build My Day Workflow SDK source
- `n8n/rhythm-adapt-my-day.ts`: validated Adapt My Day Workflow SDK source

Before deploying the scheduled source to a private n8n instance, replace
`__RHYTHM_OWNER_EMAIL__` with the single account the schedule may build for.
The production workflow keeps this value in n8n and never sends it to the browser.

## Run locally

```bash
python3 -m http.server 3000
```

Open [http://localhost:3000](http://localhost:3000), request your sign-in link, and return to the dashboard.

Supabase publishable keys and browser endpoints are designed to appear in frontend code. Database access is protected by authenticated Row Level Security policies plus a private deployment-side email allowlist. Never place a Supabase secret key or service-role key in frontend code.

## Current scope

AI is constrained to the places where judgment helps. Deterministic routing, validation, monotonic ease levels, patch limits, and persistence remain in n8n and Supabase.
