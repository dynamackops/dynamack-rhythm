import { workflow, node, trigger, newCredential, ifElse, expr } from '@n8n/workflow-sdk';

const adaptWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'POST Adapt My Day',
    parameters: {
      httpMethod: 'POST',
      path: 'rhythm-agent/adapt-day',
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
    name: 'Normalize Adapt Request',
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
const note = typeof body.note === 'string' ? body.note.trim().slice(0, 500) : '';

if (!authorization || !String(authorization).startsWith('Bearer ')) {
  throw new Error('A Supabase user session is required.');
}
if (!supabaseKey) throw new Error('Missing x-supabase-key header.');
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)) throw new Error('date must use YYYY-MM-DD.');

return [{ json: {
  date,
  note,
  headers: { apikey: String(supabaseKey), Authorization: String(authorization) },
  contextBody: { p_date: date },
} }];
`,
    },
  },
});

const loadContext = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Load Adaptation Context',
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_adapt_context',
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

const hasTargets = ifElse({
  version: 2.3,
  config: {
    name: 'Anything Can Be Easier?',
    parameters: {
      conditions: {
        options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 },
        conditions: [{
          id: 'has-adaptable-target',
          leftValue: expr('{{ Array.isArray($json.targets) && $json.targets.length > 0 }}'),
          rightValue: true,
          operator: { type: 'boolean', operation: 'equals' },
        }],
        combinator: 'and',
      },
    },
  },
});

const responseSchema = '{"type":"object","additionalProperties":false,"required":["changes","message"],"properties":{"changes":{"type":"array","minItems":1,"maxItems":2,"items":{"type":"object","additionalProperties":false,"required":["chunkId","transitionCue","movementOptionId","movementIntensity"],"properties":{"chunkId":{"type":"string"},"transitionCue":{"type":"string","maxLength":160},"movementOptionId":{"type":["string","null"]},"movementIntensity":{"type":["string","null"],"enum":["low","recovery",null]}}}},"message":{"type":"string","maxLength":160}}}';

const chooseChanges = node({
  type: '@n8n/n8n-nodes-langchain.openAi',
  version: 2.3,
  config: {
    name: 'Choose Minimum Useful Changes',
    credentials: { openAiApi: newCredential('OpenAI account') },
    parameters: {
      resource: 'text',
      operation: 'response',
      modelId: { __rl: true, mode: 'id', value: 'gpt-5.4-mini', cachedResultName: 'GPT-5.4-MINI' },
      responses: { values: [
        {
          type: 'text',
          role: 'system',
          content: 'You return CHANGES ONLY for a personal neurodivergent-friendly daily rhythm. The user pressed “Make this easier,” which is enough evidence that friction exists. Change the minimum number of items: favor NOW, and include NEXT only when it meaningfully lowers activation energy. Never change titles, order, status, or completed chunks. Never add tasks. Keep cues short, concrete, shame-free, and useful. Preserve flow in momentum mode rather than adding work. For Movement, use only IDs in easierMovementOptions; a short walk or gentle mobility may replace a harder plan. Account for the optional user note without inventing context. Use exact target IDs from the supplied context.',
        },
        {
          type: 'text',
          role: 'user',
          content: expr('{{ "Optional user note: " + ($("Normalize Adapt Request").first().json.note || "(none)") + "\nAdaptation context: " + JSON.stringify($("Load Adaptation Context").first().json) }}'),
        },
      ] },
      simplify: true,
      builtInTools: {},
      options: {
        maxTokens: 500,
        store: false,
        temperature: 0.2,
        textFormat: {
          textOptions: {
            type: 'json_schema',
            name: 'rhythm_minimum_adaptation',
            schema: responseSchema,
            description: 'At most two validated changes to NOW and NEXT, plus one gentle confirmation.',
            strict: true,
          },
        },
      },
    },
  },
});

const validateChanges = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Validate AI Changes',
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

const context = $('Load Adaptation Context').first().json;
const targets = new Map((context.targets || []).map((target) => [String(target.id), target]));
const movementIds = new Set((context.easierMovementOptions || []).map((option) => String(option.id)));
const seen = new Set();
const fallbackCues = {
  morning: 'Water, meds, and one gentle reset are enough.',
  focus: 'Choose one tiny starting point. Ten minutes is enough.',
  outside_work: 'The balcony or courtyard counts. Bring only what you need.',
  movement: 'Change into gym clothes. Gentle mobility or a short walk counts.',
  evening: 'Close one loop, then let the rest wait.',
};

const changes = [];
for (const change of Array.isArray(candidate.changes) ? candidate.changes.slice(0, 2) : []) {
  const chunkId = String(change && change.chunkId || '');
  const target = targets.get(chunkId);
  if (!target || seen.has(chunkId) || Number(target.easeLevel) >= 3) continue;
  seen.add(chunkId);

  const transitionCue = typeof change.transitionCue === 'string' && change.transitionCue.trim()
    ? change.transitionCue.trim().slice(0, 160)
    : (fallbackCues[target.key] || 'Do the smallest version that helps.');
  const isMovement = target.key === 'movement';
  const movementOptionId = isMovement && movementIds.has(String(change.movementOptionId))
    ? String(change.movementOptionId)
    : null;
  const movementIntensity = isMovement && ['low', 'recovery'].includes(change.movementIntensity)
    ? change.movementIntensity
    : null;

  changes.push({ chunkId, transitionCue, movementOptionId, movementIntensity });
}

if (!changes.length && context.targets && context.targets.length) {
  const target = context.targets[0];
  changes.push({
    chunkId: String(target.id),
    transitionCue: fallbackCues[target.key] || 'Do the smallest version that helps.',
    movementOptionId: null,
    movementIntensity: target.key === 'movement' ? 'low' : null,
  });
}

const message = typeof candidate.message === 'string' && candidate.message.trim()
  ? candidate.message.trim().slice(0, 160)
  : 'I made the smallest useful change.';

return [{ json: {
  headers: $('Normalize Adapt Request').first().json.headers,
  rpcBody: {
    p_date: context.date,
    p_changes: changes,
    p_message: message,
  },
} }];
`,
    },
  },
});

const prepareNoChange = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Already Gentle Response',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const context = $('Load Adaptation Context').first().json;
return [{ json: {
  headers: $('Normalize Adapt Request').first().json.headers,
  rpcBody: {
    p_date: context.date,
    p_changes: [],
    p_message: 'This is already at its gentlest.',
  },
} }];
`,
    },
  },
});

const applyChanges = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Apply Minimum Changes Atomically',
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_apply_adaptation',
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

export default workflow('rhythm-agent-adapt-my-day', 'Rhythm Agent — Adapt My Day')
  .add(adaptWebhook)
  .to(normalizeRequest)
  .to(loadContext)
  .to(hasTargets)
  .onTrue(chooseChanges.to(validateChanges.to(applyChanges)))
  .onFalse(prepareNoChange.to(applyChanges));
