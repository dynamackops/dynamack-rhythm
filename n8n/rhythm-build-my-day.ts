import { workflow, node, trigger, newCredential, ifElse, expr } from '@n8n/workflow-sdk';

const buildWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'POST Build My Day',
    parameters: {
      httpMethod: 'POST',
      path: 'rhythm-agent/build-day',
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

const morningSchedule = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: {
    name: '6 AM Eastern',
    parameters: {
      rule: {
        interval: [
          { field: 'days', daysInterval: 1, triggerAtHour: 6, triggerAtMinute: 0 },
        ],
      },
    },
  },
});

const normalizeManual = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Normalize Manual Request',
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

if (!authorization || !String(authorization).startsWith('Bearer ')) {
  throw new Error('A Supabase user session is required.');
}
if (!supabaseKey) throw new Error('Missing x-supabase-key header.');
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)) throw new Error('date must use YYYY-MM-DD.');

return [{ json: {
  date,
  source: 'dashboard',
  headers: { apikey: String(supabaseKey), Authorization: String(authorization) },
  contextBody: { p_date: date, p_owner_email: null },
} }];
`,
    },
  },
});

const prepareScheduled = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Scheduled Request',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const parts = new Intl.DateTimeFormat('en-US', {
  timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit'
}).formatToParts(new Date());
const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
const date = values.year + '-' + values.month + '-' + values.day;

return [{ json: {
  date,
  source: 'schedule',
  ownerEmail: '__RHYTHM_OWNER_EMAIL__',
  contextBody: { p_date: date, p_owner_email: '__RHYTHM_OWNER_EMAIL__' },
} }];
`,
    },
  },
});

const loadManualContext = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Load Manual Build Context',
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_build_context',
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
      jsonBody: expr('{{ JSON.stringify($json.contextBody) }}'),
      options: { timeout: 10000 },
    },
  },
});

const loadScheduledContext = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Load Scheduled Build Context',
    credentials: { httpHeaderAuth: newCredential('Rhythm Supabase Service') },
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_build_context',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpHeaderAuth',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: {
        parameters: [{ name: 'Content-Type', value: 'application/json' }],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($("Prepare Scheduled Request").first().json.contextBody) }}'),
      options: { timeout: 10000 },
    },
  },
});

const manualNeedsBuild = ifElse({
  version: 2.3,
  config: {
    name: 'Manual Day Missing?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{
          id: 'manual-needs-build',
          leftValue: expr('{{ $json.needsBuild }}'),
          rightValue: true,
          operator: { type: 'boolean', operation: 'equals' },
        }],
        combinator: 'and',
      },
    },
  },
});

const scheduledNeedsBuild = ifElse({
  version: 2.3,
  config: {
    name: 'Scheduled Day Missing?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{
          id: 'scheduled-needs-build',
          leftValue: expr('{{ $json.needsBuild }}'),
          rightValue: true,
          operator: { type: 'boolean', operation: 'equals' },
        }],
        combinator: 'and',
      },
    },
  },
});

const responseSchema = '{"type":"object","additionalProperties":false,"required":["movementOptionId","movementFallbackOptionId","movementIntensity","movementReason","notes"],"properties":{"movementOptionId":{"type":["string","null"]},"movementFallbackOptionId":{"type":["string","null"]},"movementIntensity":{"type":["string","null"],"enum":["normal","low","recovery",null]},"movementReason":{"type":["string","null"]},"notes":{"type":"array","maxItems":2,"items":{"type":"string"}}}}';

const adaptManualDetails = node({
  type: '@n8n/n8n-nodes-langchain.openAi',
  version: 2.3,
  config: {
    name: 'Adapt Manual Flexible Details',
    credentials: { openAiApi: newCredential('OpenAI account') },
    parameters: {
      resource: 'text',
      operation: 'response',
      modelId: { __rl: true, mode: 'id', value: 'gpt-5.4-mini', cachedResultName: 'GPT-5.4-MINI' },
      responses: { values: [
        { type: 'text', role: 'system', content: 'You adapt only the flexible details of one personal daily rhythm. Preserve the five fixed chunks and their order. Reduce friction, keep choices tiny, and never invent missing context. If the supplied context does not justify a movement choice, return null IDs and let the routine default stand. Use only IDs in the supplied movementOptions array.' },
        { type: 'text', role: 'user', content: expr('{{ "Build context: " + JSON.stringify($("Load Manual Build Context").first().json) }}') },
      ] },
      simplify: true,
      builtInTools: {},
      options: {
        maxTokens: 350,
        store: false,
        temperature: 0.2,
        textFormat: { textOptions: { type: 'json_schema', name: 'rhythm_day_flexible_details', schema: responseSchema, description: 'Only validated flexible movement details and at most two tiny notes.', strict: true } },
      },
    },
  },
});

const adaptScheduledDetails = node({
  type: '@n8n/n8n-nodes-langchain.openAi',
  version: 2.3,
  config: {
    name: 'Adapt Scheduled Flexible Details',
    credentials: { openAiApi: newCredential('OpenAI account') },
    parameters: {
      resource: 'text',
      operation: 'response',
      modelId: { __rl: true, mode: 'id', value: 'gpt-5.4-mini', cachedResultName: 'GPT-5.4-MINI' },
      responses: { values: [
        { type: 'text', role: 'system', content: 'You adapt only the flexible details of one personal daily rhythm. Preserve the five fixed chunks and their order. Reduce friction, keep choices tiny, and never invent missing context. If the supplied context does not justify a movement choice, return null IDs and let the routine default stand. Use only IDs in the supplied movementOptions array.' },
        { type: 'text', role: 'user', content: expr('{{ "Build context: " + JSON.stringify($("Load Scheduled Build Context").first().json) }}') },
      ] },
      simplify: true,
      builtInTools: {},
      options: {
        maxTokens: 350,
        store: false,
        temperature: 0.2,
        textFormat: { textOptions: { type: 'json_schema', name: 'rhythm_day_flexible_details', schema: responseSchema, description: 'Only validated flexible movement details and at most two tiny notes.', strict: true } },
      },
    },
  },
});

const validateManualSelection = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Validate Manual AI Selection',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const ai = $input.first().json;
let candidate = ai && ai.output && ai.output[0] && ai.output[0].content && ai.output[0].content[0]
  ? ai.output[0].content[0].text
  : ai;
if (typeof candidate === 'string') {
  try { candidate = JSON.parse(candidate); } catch { candidate = {}; }
}
if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) candidate = {};
const context = $('Load Manual Build Context').first().json;
const allowed = new Set((context.movementOptions || []).map((option) => String(option.id)));
const intensity = ['normal', 'low', 'recovery'].includes(candidate.movementIntensity)
  ? candidate.movementIntensity
  : null;
const notes = Array.isArray(candidate.notes)
  ? candidate.notes.filter((note) => typeof note === 'string').slice(0, 2).map((note) => note.slice(0, 160))
  : [];
const selection = {
  movementOptionId: allowed.has(String(candidate.movementOptionId)) ? String(candidate.movementOptionId) : null,
  movementFallbackOptionId: allowed.has(String(candidate.movementFallbackOptionId)) ? String(candidate.movementFallbackOptionId) : null,
  movementIntensity: intensity,
  movementReason: typeof candidate.movementReason === 'string' ? candidate.movementReason.slice(0, 240) : null,
  notes,
};

return [{ json: {
  rpcBody: {
    p_date: context.date,
    p_selection: selection,
    p_source: 'dashboard',
    p_owner_email: null,
  },
  headers: $('Normalize Manual Request').first().json.headers,
} }];
`,
    },
  },
});

const validateScheduledSelection = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Validate Scheduled AI Selection',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const ai = $input.first().json;
let candidate = ai && ai.output && ai.output[0] && ai.output[0].content && ai.output[0].content[0]
  ? ai.output[0].content[0].text
  : ai;
if (typeof candidate === 'string') {
  try { candidate = JSON.parse(candidate); } catch { candidate = {}; }
}
if (!candidate || typeof candidate !== 'object' || Array.isArray(candidate)) candidate = {};
const context = $('Load Scheduled Build Context').first().json;
const allowed = new Set((context.movementOptions || []).map((option) => String(option.id)));
const intensity = ['normal', 'low', 'recovery'].includes(candidate.movementIntensity) ? candidate.movementIntensity : null;
const notes = Array.isArray(candidate.notes) ? candidate.notes.filter((note) => typeof note === 'string').slice(0, 2).map((note) => note.slice(0, 160)) : [];
const selection = {
  movementOptionId: allowed.has(String(candidate.movementOptionId)) ? String(candidate.movementOptionId) : null,
  movementFallbackOptionId: allowed.has(String(candidate.movementFallbackOptionId)) ? String(candidate.movementFallbackOptionId) : null,
  movementIntensity: intensity,
  movementReason: typeof candidate.movementReason === 'string' ? candidate.movementReason.slice(0, 240) : null,
  notes,
};
return [{ json: { rpcBody: {
  p_date: context.date,
  p_selection: selection,
  p_source: 'schedule',
  p_owner_email: '__RHYTHM_OWNER_EMAIL__',
} } }];
`,
    },
  },
});

const keepExistingManual = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Keep Existing Manual Day',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const context = $('Load Manual Build Context').first().json;
return [{ json: {
  rpcBody: {
    p_date: context.date,
    p_selection: {},
    p_source: 'dashboard',
    p_owner_email: null,
  },
  headers: $('Normalize Manual Request').first().json.headers,
} }];
`,
    },
  },
});

const keepExistingScheduled = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Keep Existing Scheduled Day',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const context = $('Load Scheduled Build Context').first().json;
return [{ json: { rpcBody: {
  p_date: context.date,
  p_selection: {},
  p_source: 'schedule',
  p_owner_email: '__RHYTHM_OWNER_EMAIL__',
} } }];
`,
    },
  },
});

const buildManualDay = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Build Manual Day Atomically',
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_build_day',
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

const buildScheduledDay = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Build Scheduled Day Atomically',
    credentials: { httpHeaderAuth: newCredential('Rhythm Supabase Service') },
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_build_day',
      authentication: 'genericCredentialType',
      genericAuthType: 'httpHeaderAuth',
      sendHeaders: true,
      specifyHeaders: 'keypair',
      headerParameters: {
        parameters: [{ name: 'Content-Type', value: 'application/json' }],
      },
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ JSON.stringify($json.rpcBody) }}'),
      options: { timeout: 15000 },
    },
  },
});

export default workflow('rhythm-agent-build-my-day', 'Rhythm Agent — Build My Day')
  .add(buildWebhook)
  .to(normalizeManual)
  .to(loadManualContext)
  .to(manualNeedsBuild)
  .onTrue(adaptManualDetails.to(validateManualSelection.to(buildManualDay)))
  .onFalse(keepExistingManual.to(buildManualDay))
  .add(morningSchedule)
  .to(prepareScheduled)
  .to(loadScheduledContext)
  .to(scheduledNeedsBuild)
  .onTrue(adaptScheduledDetails.to(validateScheduledSelection.to(buildScheduledDay)))
  .onFalse(keepExistingScheduled.to(buildScheduledDay));
