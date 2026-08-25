import { workflow, node, trigger, expr } from '@n8n/workflow-sdk';

const actionWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'POST Rhythm Action',
    parameters: {
      httpMethod: 'POST',
      path: 'rhythm-agent/action',
      authentication: 'none',
      responseMode: 'responseNode',
      options: { allowedOrigins: '*' },
    },
  },
});

const normalizeRequest = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Normalize and Validate Action',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const input = $input.first().json;
const body = input.body || {};
const headers = input.headers || {};
const action = String(body.action || 'get_state');
const allowed = [
  'get_state', 'complete', 'start', 'reset_today', 'make_day', 'make_easier',
  'accept_prompt', 'snooze_prompt', 'dismiss_prompt', 'close_out',
  'meal_help', 'select_meal', 'pantry_gone', 'log_food', 'delete_food_log',
  'toggle_routine', 'swap_cleaning', 'set_theme', 'set_lofi'
];

if (!allowed.includes(action)) throw new Error('Unsupported Rhythm action: ' + action);

const authorization = headers.authorization || headers.Authorization;
if (!authorization || !String(authorization).startsWith('Bearer ')) {
  throw new Error('A Supabase user session is required.');
}

const supabaseKey = headers['x-supabase-key'] || headers['X-Supabase-Key'];
if (!supabaseKey) throw new Error('Missing x-supabase-key header.');

const date = String(body.date || '');
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)) throw new Error('date must use YYYY-MM-DD.');

let targetUrl = 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_phase6_action';
let requestBody = {
  p_action: action,
  p_date: date,
  p_chunk_id: body.chunkId || null,
  p_prompt_id: body.promptId || null,
  p_mood: null,
  p_note: null,
  p_effort: null,
  p_meal_id: null,
  p_pantry_item_id: null,
  p_routine_step_id: body.routineStepId || null,
  p_theme: typeof body.theme === 'string' ? body.theme : null,
  p_lofi_enabled: typeof body.lofiEnabled === 'boolean' ? body.lofiEnabled : null,
};

if (action === 'make_day') {
  targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/build-day';
  requestBody = { date };
} else if (action === 'make_easier') {
  targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/adapt-day';
  requestBody = {
    date,
    note: typeof body.note === 'string' ? body.note.trim().slice(0, 500) : null,
  };
} else if (action === 'close_out') {
  targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/close-out-day';
  requestBody = {
    date,
    promptId: body.promptId || null,
    mood: typeof body.mood === 'string' ? body.mood : null,
    note: typeof body.note === 'string' ? body.note.trim().slice(0, 280) : null,
  };
} else if (['meal_help', 'select_meal', 'pantry_gone', 'log_food', 'delete_food_log'].includes(action)) {
  targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/meal-help';
  requestBody = {
    action,
    date,
    effort: typeof body.effort === 'string' ? body.effort : null,
    mealId: body.mealId || null,
    mealSlot: typeof body.mealSlot === 'string' ? body.mealSlot : 'dinner',
    pantryItemId: body.pantryItemId || null,
    foodName: typeof body.foodName === 'string' ? body.foodName.trim().slice(0, 120) : null,
    foodSlot: typeof body.foodSlot === 'string' ? body.foodSlot : null,
    source: typeof body.source === 'string' ? body.source : 'home',
    placeName: typeof body.placeName === 'string' ? body.placeName.trim().slice(0, 80) : null,
    logId: body.logId || null,
  };
}

return [{ json: {
  action,
  date,
  chunkId: body.chunkId || null,
  headers: { apikey: String(supabaseKey), Authorization: String(authorization) },
  targetUrl,
  requestBody,
} }];
`,
    },
  },
});

const callRoutedAction = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Call Routed Rhythm Action',
    parameters: {
      method: 'POST',
      url: expr('{{ $json.targetUrl }}'),
      authentication: 'none',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: {
        parameters: [
          { name: 'apikey', value: expr('{{ $json.headers.apikey }}') },
          { name: 'Authorization', value: expr('{{ $json.headers.Authorization }}') },
          { name: 'x-supabase-key', value: expr('{{ $json.headers.apikey }}') },
          { name: 'Content-Type', value: 'application/json' },
        ],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($json.requestBody) }}'),
      options: { timeout: 60000 },
    },
  },
});

const respond = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Return Dashboard State',
    parameters: {
      respondWith: 'firstIncomingItem',
      enableStreaming: false,
      options: {
        responseCode: 200,
        responseHeaders: {
          entries: [
            { name: 'Content-Type', value: 'application/json; charset=utf-8' },
            { name: 'Access-Control-Allow-Origin', value: '*' },
          ],
        },
      },
    },
  },
});

export default workflow('rhythm-agent-router-phase-6', 'Rhythm Agent Router — Routines & Themes')
  .add(actionWebhook)
  .to(normalizeRequest)
  .to(callRoutedAction)
  .to(respond);
