import { workflow, node, trigger, ifElse, expr } from '@n8n/workflow-sdk';

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
const allowed = ['get_state', 'complete', 'start', 'reset_today', 'make_day'];

if (!allowed.includes(action)) throw new Error('Unsupported Rhythm action: ' + action);

const authorization = headers.authorization || headers.Authorization;
if (!authorization || !String(authorization).startsWith('Bearer ')) {
  throw new Error('A Supabase user session is required.');
}

const supabaseKey = headers['x-supabase-key'] || headers['X-Supabase-Key'];
if (!supabaseKey) throw new Error('Missing x-supabase-key header.');

const date = String(body.date || '');
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)) throw new Error('date must use YYYY-MM-DD.');

return [{ json: {
  action,
  date,
  chunkId: body.chunkId || null,
  headers: { apikey: String(supabaseKey), Authorization: String(authorization) },
  rpcUrl: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_apply_action',
  rpcBody: { p_action: action, p_date: date, p_chunk_id: body.chunkId || null },
  buildUrl: 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/build-day',
  buildBody: { date },
} }];
`,
    },
  },
});

const isMakeDay = ifElse({
  version: 2.3,
  config: {
    name: 'Make Day?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{
          id: 'make-day',
          leftValue: expr('{{ $json.action }}'),
          rightValue: 'make_day',
          operator: { type: 'string', operation: 'equals' },
        }],
        combinator: 'and',
      },
    },
  },
});

const callBuildMyDay = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Call Build My Day',
    parameters: {
      method: 'POST',
      url: expr('{{ $json.buildUrl }}'),
      authentication: 'none',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: { parameters: [
        { name: 'apikey', value: expr('{{ $json.headers.apikey }}') },
        { name: 'Authorization', value: expr('{{ $json.headers.Authorization }}') },
        { name: 'x-supabase-key', value: expr('{{ $json.headers.apikey }}') },
        { name: 'Content-Type', value: 'application/json' },
      ] },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($json.buildBody) }}'),
      options: { timeout: 60000 },
    },
  },
});

const applyAtomicAction = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Apply Atomic Rhythm Action',
    parameters: {
      method: 'POST',
      url: expr('{{ $json.rpcUrl }}'),
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
      options: { timeout: 10000 },
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

export default workflow('rhythm-agent-router-phase-2', 'Rhythm Agent Router — Phase 2')
  .add(actionWebhook)
  .to(normalizeRequest)
  .to(isMakeDay)
  .onTrue(callBuildMyDay.to(respond))
  .onFalse(applyAtomicAction.to(respond));
