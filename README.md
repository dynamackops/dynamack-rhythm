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

## Architecture

- `index.html`, `styles.css`, and `app.js`: visual dashboard
- Supabase project `Rhythm Agent`: `routine_templates`, `daily_plans`, and `chunks`
- n8n workflow `Rhythm Agent Router — Phase 1`: authenticated `get_state`, `complete`, and `start` actions
- `config.example.js`: public-safe template for private runtime settings
- `supabase/phase1_schema.sql`: reproducible Phase 1 database definition
- `n8n/rhythm-router.ts`: validated Workflow SDK source

## Run locally

```bash
cp config.example.js config.js
python3 -m http.server 3000
```

Fill in `config.js`, open [http://localhost:3000](http://localhost:3000), request your sign-in link, and return to the dashboard. `config.js` is ignored by Git and must not be committed.

Supabase publishable keys are designed for frontend use, but this project still keeps all account-specific values in the ignored runtime config. Database access is protected by authenticated Row Level Security policies. Never place a Supabase secret key or service-role key in frontend code.

## Current scope

This repository intentionally contains no AI behavior yet. “Make this easier” begins in Phase 3 after the deterministic Phase 1 loop and Phase 2 daily-plan builder are proven.
