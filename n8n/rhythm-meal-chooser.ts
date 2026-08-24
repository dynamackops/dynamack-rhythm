import { workflow, node, trigger, expr } from '@n8n/workflow-sdk';

const mealWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'POST Meal Help',
    parameters: {
      httpMethod: 'POST',
      path: 'rhythm-agent/meal-help',
      authentication: 'none',
      responseMode: 'lastNode',
      responseData: 'firstEntryJson',
      options: {
        allowedOrigins: '*',
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

const normalizeRequest = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Validate Meal Request',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const input = $input.first().json;
const body = input.body || {};
const headers = input.headers || {};
const authorization = headers.authorization || headers.Authorization;
const supabaseKey = headers['x-supabase-key'] || headers['X-Supabase-Key'];
const action = String(body.action || 'meal_help');
const date = String(body.date || '');
const effort = body.effort == null ? null : String(body.effort);
const mealSlot = body.mealSlot == null ? 'dinner' : String(body.mealSlot);

if (!authorization || !String(authorization).startsWith('Bearer ')) {
  throw new Error('A Supabase user session is required.');
}
if (!supabaseKey) throw new Error('Missing x-supabase-key header.');
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)) throw new Error('date must use YYYY-MM-DD.');
if (!['meal_help', 'select_meal', 'pantry_gone'].includes(action)) {
  throw new Error('Unsupported meal action: ' + action);
}
if (effort && !['any', 'no_cook', 'very_easy', 'cook_a_little'].includes(effort)) {
  throw new Error('Unknown meal effort.');
}
if (!['breakfast', 'lunch', 'dinner'].includes(mealSlot)) {
  throw new Error('Unknown meal slot.');
}

return [{ json: {
  headers: { apikey: String(supabaseKey), Authorization: String(authorization) },
  rpcBody: {
    p_action: action,
    p_date: date,
    p_effort: effort,
    p_meal_id: body.mealId || null,
    p_pantry_item_id: body.pantryItemId || null,
    p_meal_slot: mealSlot,
  },
} }];
`,
    },
  },
});

const chooseMeal = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Filter Available Meals',
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_all_day_meal_action',
      authentication: 'none',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: {
        parameters: [
          { name: 'apikey', value: expr('{{ $json.headers.apikey }}') },
          { name: 'Authorization', value: expr('{{ $json.headers.Authorization }}') },
          { name: 'Content-Type', value: 'application/json' },
        ],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($json.rpcBody) }}'),
      options: { timeout: 15000 },
    },
  },
});

export default workflow('rhythm-agent-meal-chooser', 'Rhythm Agent — Meal Chooser')
  .add(mealWebhook)
  .to(normalizeRequest)
  .to(chooseMeal);
