import { workflow, node, trigger, expr } from '@n8n/workflow-sdk';

const resetWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'POST Close Out the Day',
    parameters: {
      httpMethod: 'POST',
      path: 'rhythm-agent/close-out-day',
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
    name: 'Validate Tiny Reflection',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const input = $input.first().json;
const body = input.body || {};
const headers = input.headers || {};
const authorization = headers.authorization || headers.Authorization;
const supabaseKey = headers['x-supabase-key'] || headers['X-Supabase-Key'];
const date = String(body.date || '');
const mood = String(body.mood || '');
const note = typeof body.note === 'string' ? body.note.trim().slice(0, 280) : null;

if (!authorization || !String(authorization).startsWith('Bearer ')) {
  throw new Error('A Supabase user session is required.');
}
if (!supabaseKey) throw new Error('Missing x-supabase-key header.');
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)) throw new Error('date must use YYYY-MM-DD.');
if (!['good', 'meh', 'hard'].includes(mood)) throw new Error('Choose Good, Meh, or Hard.');

return [{ json: {
  headers: { apikey: String(supabaseKey), Authorization: String(authorization) },
  rpcBody: {
    p_action: 'close_out',
    p_date: date,
    p_chunk_id: null,
    p_prompt_id: body.promptId || null,
    p_mood: mood,
    p_note: note,
  },
} }];
`,
    },
  },
});

const saveHistory = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Save Close Out Atomically',
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_phase5_action',
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

export default workflow('rhythm-agent-evening-reset', 'Rhythm Agent — Evening Reset')
  .add(resetWebhook)
  .to(normalizeRequest)
  .to(saveHistory);
