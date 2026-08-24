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

## Phase 4

Phase 4 adds low-friction food support without turning the pantry into another chore:

- tracks groceries primarily as **Available / Running low / Gone**
- accepts shopping-order summaries as import batches, so pickup screenshots can refresh the pantry
- keeps optional counts only where they are genuinely helpful
- offers at most three meals from **No cooking / Very easy / I can cook a little**
- filters deterministically against food that is actually available
- saves one dinner choice to today so the decision does not need to be made twice
- starts with nine personal meals built around the current groceries and available appliances

## Phase 5

Phase 5 adds time awareness without turning Rhythm into a rigid schedule:

- checks for a due transition every 10 minutes in Eastern time
- surfaces at most one suggestion and never changes chunks automatically
- offers **Start now / 15 more minutes / Stay here for now**
- treats 4–5 PM as a “change into gym clothes, then relax” preparation bridge
- keeps 6–7 PM as a simple dinner bridge until Meal Chooser is built
- offers **Close out the day** at 9 PM while keeping the button manually available
- records **😊 Good / 😐 Meh / 😩 Hard** and one optional short note
- saves a compact day-history snapshot and expires unfinished routine chunks without overdue guilt

## Conversational Rhythm Agent

The dashboard now includes one lightweight **“Tell Rhythm what’s going on”** input. Every request retrieves the current state first, and the model may choose at most one allowlisted action. It cannot write arbitrary database records.

- uses existing safe actions for easing, energy, chunks, meals, transitions, and close-out
- validates chunk, prompt, meal, energy, and mood values against current state
- preserves the day when guidance is enough
- never claims a meeting, pantry item, or personal detail was saved when it was not
- returns one or two brief, shame-free sentences explaining what changed

## Rhythm Learning

**Your rhythm lately** looks for supportive patterns across the latest 14–28 days. Deterministic SQL computes the evidence first; AI can only rephrase supported pattern IDs.

- waits for at least three closed-out days before naming a pattern
- compares energy, chunk easing/completion, meal effort, and movement fallback use
- does not show streaks, scores, productivity percentages, red flags, or failure language
- returns a gentle “still learning” state when the evidence is thin
- creates no analytics profile and no new persistence table

## Architecture

- `index.html`, `styles.css`, and `app.js`: visual dashboard
- Supabase project `Rhythm Agent`: `routine_templates`, `daily_plans`, and `chunks`
- n8n workflow `Rhythm Agent Router — Phase 4`: authenticated state, chunk, prompt, meal, adaptation, and close-out actions
- n8n workflow `Rhythm Agent — Build My Day`: scheduled and authenticated daily-plan builder
- n8n workflow `Rhythm Agent — Adapt My Day`: authenticated, changes-only easing workflow
- n8n workflow `Rhythm Agent — Chunk Transition`: deterministic 10-minute transition check
- n8n workflow `Rhythm Agent — Evening Reset`: authenticated close-out and history workflow
- n8n workflow `Rhythm Agent — Meal Chooser`: pantry-aware deterministic dinner choices
- n8n workflow `Rhythm Agent — Conversation`: current-state-first, single-tool conversational routing
- n8n workflow `Rhythm Agent — Learn My Rhythm`: deterministic recent-history patterns with evidence-bound summaries
- `config.js`: browser-safe runtime settings; contains no email address or secret key
- `config.example.js`: reusable configuration template
- `supabase/phase1_schema.sql`: reproducible Phase 1 database definition
- `supabase/phase2_build_my_day.sql`: movement library and duplicate-safe plan builder
- `supabase/phase2_dashboard_state.sql`: Phase 2 dashboard-state response
- `supabase/phase3_adapt_my_day.sql`: adaptation context and atomic minimal-patch RPC
- `supabase/phase5_transitions_and_closeout.sql`: prompt lifecycle, close-out check-ins, and day history
- `supabase/phase4_meal_chooser.sql`: grocery imports, loose pantry state, meal library, and dinner selection
- `supabase/phase7_conversation_learning.sql`: narrow energy action and read-only learning aggregates
- `n8n/rhythm-router.ts`: validated Workflow SDK source
- `n8n/rhythm-build-my-day.ts`: validated Build My Day Workflow SDK source
- `n8n/rhythm-adapt-my-day.ts`: validated Adapt My Day Workflow SDK source
- `n8n/rhythm-chunk-transition.ts`: validated scheduled transition Workflow SDK source
- `n8n/rhythm-evening-reset.ts`: validated close-out Workflow SDK source
- `n8n/rhythm-meal-chooser.ts`: validated Meal Chooser Workflow SDK source
- `n8n/rhythm-conversation.ts`: validated conversational Workflow SDK source
- `n8n/rhythm-learn-my-rhythm.ts`: validated learning Workflow SDK source

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
