import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.0';
import {
  SUPABASE_URL,
  SUPABASE_PUBLISHABLE_KEY,
  RHYTHM_ACTION_URL,
} from './config.js';

const supabase = createClient(SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY, {
  auth: { persistSession: true, detectSessionInUrl: true },
});

const energyLabels = {
  normal: '🟢 Normal',
  low_energy: '🟡 Low energy',
  recovery: '🔴 Recovery',
  overwhelmed: '🧠 Overwhelmed',
  momentum: '🔥 Momentum',
};

const authView = document.querySelector('#auth-view');
const dashboardView = document.querySelector('#dashboard-view');
const loginForm = document.querySelector('#login-form');
const authMessage = document.querySelector('#auth-message');
const dashboardMessage = document.querySelector('#dashboard-message');
const refreshButton = document.querySelector('#refresh-button');
const signoutButton = document.querySelector('#signout-button');
const nowContent = document.querySelector('#now-content');
const nextContent = document.querySelector('#next-content');
const laterContent = document.querySelector('#later-content');
const energyPill = document.querySelector('#energy-pill');
const todayLabel = document.querySelector('#today-label');
const progressLabel = document.querySelector('#progress-label');
const nowTemplate = document.querySelector('#now-template');
const smallChunkTemplate = document.querySelector('#small-chunk-template');

let session = null;
let state = null;
let busy = false;

function easternDate() {
  const parts = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(new Date());
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

function friendlyDate(date) {
  return new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York', weekday: 'long', month: 'long', day: 'numeric',
  }).format(new Date(`${date}T12:00:00-04:00`));
}

function setBusy(value, message = '') {
  busy = value;
  document.querySelectorAll('button').forEach((button) => { button.disabled = value; });
  if (message) dashboardMessage.textContent = message;
}

function showAuth() {
  authView.hidden = false;
  dashboardView.hidden = true;
}

function showDashboard() {
  authView.hidden = true;
  dashboardView.hidden = false;
}

async function initializeToday() {
  const date = easternDate();
  const userId = session.user.id;
  const { data: existing, error: existingError } = await supabase
    .from('daily_plans')
    .select('id')
    .eq('owner_id', userId)
    .eq('plan_date', date)
    .maybeSingle();

  if (existingError) throw existingError;
  if (existing) return existing.id;

  const { data: template, error: templateError } = await supabase
    .from('routine_templates')
    .select('chunks_json')
    .eq('is_default', true)
    .single();
  if (templateError) throw templateError;

  const { data: plan, error: planError } = await supabase
    .from('daily_plans')
    .insert({ owner_id: userId, plan_date: date, energy_mode: 'normal', status: 'active' })
    .select('id')
    .single();
  if (planError) throw planError;

  const rows = template.chunks_json.map((chunk, index) => ({
    owner_id: userId,
    daily_plan_id: plan.id,
    template_key: chunk.key,
    title: chunk.title,
    position: chunk.position,
    status: index === 0 ? 'current' : index === 1 ? 'next' : 'later',
    transition_cue: chunk.cue || null,
    started_at: index === 0 ? new Date().toISOString() : null,
  }));

  const { error: chunksError } = await supabase.from('chunks').insert(rows);
  if (chunksError) throw chunksError;
  return plan.id;
}

async function callRhythm(action = 'get_state', chunkId = null) {
  const response = await fetch(RHYTHM_ACTION_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${session.access_token}`,
      'x-supabase-key': SUPABASE_PUBLISHABLE_KEY,
    },
    body: JSON.stringify({ action, chunkId, date: easternDate() }),
  });

  const payload = await response.json().catch(() => null);
  if (!response.ok || !payload?.ok) {
    throw new Error(payload?.message || payload?.error || `Rhythm request failed (${response.status}).`);
  }
  return payload;
}

function makeSmallChunk(chunk, context) {
  const node = smallChunkTemplate.content.cloneNode(true);
  node.querySelector('h3').textContent = chunk.title;
  const note = node.querySelector('p');
  note.textContent = chunk.transition_cue || (context === 'next' ? 'Ready when you are.' : 'It can wait.');
  const button = node.querySelector('button');
  button.dataset.chunkId = chunk.id;
  button.setAttribute('aria-label', `Start ${chunk.title}`);
  button.addEventListener('click', () => runAction('start', chunk.id));
  return node;
}

function renderState() {
  nowContent.replaceChildren();
  nextContent.replaceChildren();
  laterContent.replaceChildren();

  todayLabel.textContent = friendlyDate(state.date);
  energyPill.textContent = energyLabels[state.energyMode] || energyLabels.normal;

  if (state.now) {
    const node = nowTemplate.content.cloneNode(true);
    node.querySelector('.now-title').textContent = state.now.title;
    const cue = node.querySelector('.transition-cue');
    cue.textContent = state.now.transition_cue || 'You only need to be here right now.';
    node.querySelector('.complete-button').addEventListener('click', () => runAction('complete'));
    nowContent.append(node);
  } else {
    nowContent.innerHTML = '<div><p class="chunk-kicker">Today is complete</p><h2 class="now-title">Exhale.</h2><p class="transition-cue">Nothing else needs to become overdue.</p></div>';
    if (state.chunks.length > 0 && state.completed.length === state.chunks.length) {
      const recoveryButton = document.createElement('button');
      recoveryButton.className = 'recovery-button';
      recoveryButton.type = 'button';
      recoveryButton.textContent = 'Reopen today';
      recoveryButton.addEventListener('click', () => runAction('reset_today'));
      nowContent.firstElementChild.append(recoveryButton);
    }
  }

  if (state.next) nextContent.append(makeSmallChunk(state.next, 'next'));
  else nextContent.innerHTML = '<p class="empty-copy">No next chunk. Stay where you are.</p>';

  if (state.later.length) state.later.forEach((chunk) => laterContent.append(makeSmallChunk(chunk, 'later')));
  else laterContent.innerHTML = '<p class="empty-copy">Nothing waiting in the wings.</p>';

  const total = state.chunks.length;
  progressLabel.textContent = `${state.completed.length} of ${total} chunks complete`;
}

async function loadDashboard(message = 'Making today visible…') {
  setBusy(true, message);
  try {
    await initializeToday();
    state = await callRhythm('get_state');
    renderState();
    dashboardMessage.textContent = '';
  } catch (error) {
    console.error(error);
    dashboardMessage.textContent = error.message || 'Rhythm could not load yet.';
  } finally {
    setBusy(false);
  }
}

async function runAction(action, chunkId = null) {
  if (busy) return;
  const actionMessages = {
    complete: 'Moving gently to what comes next…',
    start: 'Starting that chunk…',
    reset_today: 'Reopening today…',
  };
  setBusy(true, actionMessages[action] || 'Updating your rhythm…');
  try {
    state = await callRhythm(action, chunkId);
    renderState();
    dashboardMessage.textContent = '';
  } catch (error) {
    console.error(error);
    dashboardMessage.textContent = error.message || 'That change did not save.';
  } finally {
    setBusy(false);
  }
}

loginForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  const email = new FormData(loginForm).get('email').trim().toLowerCase();
  authMessage.textContent = 'Sending your private sign-in link…';
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: `${window.location.origin}${window.location.pathname}` },
  });
  authMessage.textContent = error ? error.message : 'Check your email, then open the link on this device.';
});

refreshButton.addEventListener('click', () => loadDashboard('Refreshing your rhythm…'));
signoutButton.addEventListener('click', async () => {
  await supabase.auth.signOut();
  session = null;
  state = null;
  showAuth();
});

supabase.auth.onAuthStateChange((_event, nextSession) => {
  session = nextSession;
  if (session) {
    showDashboard();
    queueMicrotask(() => loadDashboard());
  } else {
    showAuth();
  }
});

const { data: { session: initialSession } } = await supabase.auth.getSession();
session = initialSession;
if (session) {
  showDashboard();
  await loadDashboard();
} else {
  showAuth();
}
