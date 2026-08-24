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
const closeoutButton = document.querySelector('#closeout-button');
const mealHelpButton = document.querySelector('#meal-help-button');
const mealDialog = document.querySelector('#meal-dialog');
const mealClose = document.querySelector('#meal-close');
const mealResults = document.querySelector('#meal-results');
const transitionPrompt = document.querySelector('#transition-prompt');
const transitionTitle = document.querySelector('#transition-title');
const transitionMessage = document.querySelector('#transition-message');
const promptPrimary = document.querySelector('#prompt-primary');
const promptSnooze = document.querySelector('#prompt-snooze');
const promptDismiss = document.querySelector('#prompt-dismiss');
const closeoutDialog = document.querySelector('#closeout-dialog');
const closeoutForm = document.querySelector('#closeout-form');
const closeoutNote = document.querySelector('#closeout-note');
const closeoutSubmit = document.querySelector('#closeout-submit');
const closeoutCancel = document.querySelector('#closeout-cancel');
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
let busyCount = 0;
let selectedMood = null;

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
  busyCount = value ? busyCount + 1 : Math.max(0, busyCount - 1);
  busy = busyCount > 0;
  document.querySelectorAll('button').forEach((button) => {
    if (busy && button.dataset.rhythmWasDisabled === undefined) {
      button.dataset.rhythmWasDisabled = button.disabled ? '1' : '0';
      button.disabled = true;
    } else if (!busy && button.dataset.rhythmWasDisabled !== undefined) {
      button.disabled = button.dataset.rhythmWasDisabled === '1';
      delete button.dataset.rhythmWasDisabled;
    }
  });
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

async function callRhythm(action = 'get_state', chunkId = null, extra = {}) {
  const response = await fetch(RHYTHM_ACTION_URL, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${session.access_token}`,
      'x-supabase-key': SUPABASE_PUBLISHABLE_KEY,
    },
    body: JSON.stringify({ action, chunkId, date: easternDate(), ...extra }),
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
  const time = node.querySelector('.small-time');
  const note = node.querySelector('.small-note');
  const movementPlan = chunk.title === 'Movement' && state.movement?.optionTitle
    ? `${state.movement.optionTitle}${state.movement.intensity ? ` · ${state.movement.intensity}` : ''}`
    : null;
  time.textContent = state.schedule?.[chunk.template_key] || '';
  note.textContent = movementPlan || chunk.transition_cue || (context === 'next' ? 'Ready when you are.' : 'It can wait.');
  const button = node.querySelector('button');
  button.dataset.chunkId = chunk.id;
  button.setAttribute('aria-label', `Start ${chunk.title}`);
  button.addEventListener('click', () => runAction('start', chunk.id));
  return node;
}

function openCloseout() {
  selectedMood = null;
  closeoutNote.value = '';
  closeoutSubmit.disabled = true;
  document.querySelectorAll('.mood-button').forEach((button) => button.classList.remove('selected'));
  closeoutDialog.showModal();
}

function renderTransitionPrompt() {
  const prompt = state.transitionPrompt;
  transitionPrompt.hidden = !prompt;
  if (!prompt) return;

  transitionTitle.textContent = prompt.title;
  transitionMessage.textContent = prompt.message;
  promptPrimary.textContent = prompt.type === 'transition'
    ? 'Start now'
    : prompt.type === 'preparation'
      ? 'Start getting ready'
      : prompt.type === 'close_out'
        ? 'Close out the day'
        : 'Got it';
}

function effortForEnergy() {
  if (['recovery', 'overwhelmed'].includes(state?.energyMode)) return 'no_cook';
  if (state?.energyMode === 'low_energy') return 'very_easy';
  return 'very_easy';
}

function renderMealButton() {
  const dinner = state?.dinnerChoice;
  mealHelpButton.textContent = dinner ? `🍽️ Dinner: ${dinner.title}` : '🍽️ What can I eat?';
  mealHelpButton.title = dinner?.instructions || 'Get a few small meal choices from what is available.';
}

function renderMealChoices() {
  mealResults.replaceChildren();
  const choices = state?.mealChoices;
  if (!Array.isArray(choices) || choices.length === 0) {
    mealResults.innerHTML = '<p class="empty-copy">Nothing matched this effort level. Try another one—no need to force it.</p>';
    return;
  }

  choices.forEach((meal) => {
    const card = document.createElement('article');
    card.className = 'meal-card';
    const ingredients = meal.ingredients
      .filter((ingredient) => ingredient.required)
      .map((ingredient) => ingredient.name)
      .join(' · ');
    card.innerHTML = `
      <div>
        <p class="meal-meta">${meal.minutes} minutes</p>
        <h3></h3>
        <p class="meal-ingredients"></p>
        <p class="meal-instructions"></p>
        <p class="meal-support"></p>
      </div>
    `;
    card.querySelector('h3').textContent = meal.title;
    card.querySelector('.meal-ingredients').textContent = ingredients;
    card.querySelector('.meal-instructions').textContent = meal.instructions;
    card.querySelector('.meal-support').textContent = meal.supportiveNote || '';
    const choose = document.createElement('button');
    choose.className = 'complete-button';
    choose.type = 'button';
    choose.textContent = 'Choose this';
    choose.addEventListener('click', async () => {
      mealDialog.close();
      await runAction('select_meal', null, { mealId: meal.id });
      dashboardMessage.textContent = `Dinner is ${state.dinnerChoice?.title || 'chosen'}. One less decision.`;
    });
    card.append(choose);
    mealResults.append(card);
  });
}

async function requestMeals(effort) {
  if (busy) return;
  document.querySelectorAll('.effort-button').forEach((button) => {
    button.classList.toggle('selected', button.dataset.effort === effort);
  });
  setBusy(true, 'Looking only at what you already have…');
  mealResults.innerHTML = '<p class="empty-copy">Finding a few useful choices…</p>';
  try {
    state = await callRhythm('meal_help', null, { effort });
    renderState();
    renderMealChoices();
    dashboardMessage.textContent = '';
  } catch (error) {
    console.error(error);
    mealResults.replaceChildren();
    const errorCopy = document.createElement('p');
    errorCopy.className = 'empty-copy';
    errorCopy.textContent = error.message || 'Meal help could not load yet.';
    mealResults.append(errorCopy);
  } finally {
    setBusy(false);
  }
}

function renderState() {
  nowContent.replaceChildren();
  nextContent.replaceChildren();
  laterContent.replaceChildren();

  todayLabel.textContent = friendlyDate(state.date);
  energyPill.textContent = energyLabels[state.energyMode] || energyLabels.normal;
  renderMealButton();
  closeoutButton.hidden = !state.closeOut?.available;
  renderTransitionPrompt();

  if (state.needsSetup) {
    const setup = document.createElement('div');
    setup.innerHTML = '<p class="chunk-kicker">A fresh start</p><h2 class="now-title">Ready?</h2><p class="transition-cue">We can make today visible without deciding everything at once.</p>';
    const startButton = document.createElement('button');
    startButton.className = 'complete-button';
    startButton.type = 'button';
    startButton.textContent = 'Start my day';
    startButton.addEventListener('click', () => runAction('make_day'));
    const actions = document.createElement('div');
    actions.className = 'now-actions';
    actions.append(startButton);
    setup.append(actions);
    nowContent.append(setup);
    nextContent.innerHTML = '<p class="empty-copy">Nothing to hold in your head yet.</p>';
    laterContent.innerHTML = '<p class="empty-copy">Later can wait.</p>';
    progressLabel.textContent = 'Your rhythm has not started yet';
    return;
  }

  if (state.closeOut?.closed) {
    const moodLabels = { good: '😊 Good', meh: '😐 Meh', hard: '😩 Hard' };
    const closed = document.createElement('div');
    closed.innerHTML = `<p class="chunk-kicker">Day closed</p><h2 class="now-title">Exhale.</h2><p class="transition-cue">Today felt ${moodLabels[state.dayHistory?.mood] || 'complete'}. Nothing unfinished became overdue.</p>`;
    nowContent.append(closed);
    nextContent.innerHTML = '<p class="empty-copy">Tomorrow gets a fresh start.</p>';
    laterContent.innerHTML = '<p class="empty-copy">The rest can wait.</p>';
    progressLabel.textContent = `${state.dayHistory?.completedCount || 0} completed · ${state.dayHistory?.unfinishedCount || 0} gently released`;
    return;
  }

  if (state.now) {
    const node = nowTemplate.content.cloneNode(true);
    node.querySelector('.now-title').textContent = state.now.title;
    node.querySelector('.chunk-time').textContent = state.schedule?.[state.now.template_key] || '';
    const cue = node.querySelector('.transition-cue');
    cue.textContent = state.now.transition_cue || 'You only need to be here right now.';
    node.querySelector('.complete-button').addEventListener('click', () => runAction('complete'));
    node.querySelector('.easier-button').addEventListener('click', () => runAction('make_easier'));
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

async function runAction(action, chunkId = null, extra = {}) {
  if (busy) return;
  const actionMessages = {
    complete: 'Moving gently to what comes next…',
    start: 'Starting that chunk…',
    reset_today: 'Reopening today…',
    make_day: 'Building a gentle shape for today…',
    make_easier: 'Making the smallest useful change…',
    accept_prompt: 'Moving when you are ready…',
    snooze_prompt: 'Giving you 15 more minutes…',
    dismiss_prompt: 'Staying here for now…',
    close_out: 'Closing out the day gently…',
    select_meal: 'Saving one less decision for later…',
  };
  setBusy(true, actionMessages[action] || 'Updating your rhythm…');
  try {
    state = await callRhythm(action, chunkId, extra);
    renderState();
    dashboardMessage.textContent = state.adaptation?.message || '';
  } catch (error) {
    console.error(error);
    dashboardMessage.textContent = error.message || 'That change did not save.';
  } finally {
    setBusy(false);
  }
}

promptPrimary.addEventListener('click', () => {
  const prompt = state?.transitionPrompt;
  if (!prompt) return;
  if (prompt.type === 'close_out') openCloseout();
  else runAction('accept_prompt', null, { promptId: prompt.id });
});
promptSnooze.addEventListener('click', () => {
  if (state?.transitionPrompt) runAction('snooze_prompt', null, { promptId: state.transitionPrompt.id });
});
promptDismiss.addEventListener('click', () => {
  if (state?.transitionPrompt) runAction('dismiss_prompt', null, { promptId: state.transitionPrompt.id });
});

closeoutButton.addEventListener('click', openCloseout);
mealHelpButton.addEventListener('click', () => {
  mealDialog.showModal();
  requestMeals(effortForEnergy());
});
mealClose.addEventListener('click', () => mealDialog.close());
document.querySelectorAll('.effort-button').forEach((button) => {
  button.addEventListener('click', () => requestMeals(button.dataset.effort));
});
closeoutCancel.addEventListener('click', () => closeoutDialog.close());
document.querySelectorAll('.mood-button').forEach((button) => {
  button.addEventListener('click', () => {
    selectedMood = button.dataset.mood;
    document.querySelectorAll('.mood-button').forEach((option) => option.classList.toggle('selected', option === button));
    closeoutSubmit.disabled = false;
  });
});
closeoutForm.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (!selectedMood) return;
  const promptId = state?.transitionPrompt?.type === 'close_out' ? state.transitionPrompt.id : null;
  closeoutDialog.close();
  await runAction('close_out', null, { mood: selectedMood, note: closeoutNote.value.trim(), promptId });
});

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

window.setInterval(() => {
  if (session && !busy && document.visibilityState === 'visible') loadDashboard('Checking the rhythm…');
}, 5 * 60 * 1000);
