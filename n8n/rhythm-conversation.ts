import { workflow, node, trigger, newCredential, ifElse, expr } from '@n8n/workflow-sdk';

const chatWebhook = trigger({
  type: 'n8n-nodes-base.webhook',
  version: 2.1,
  config: {
    name: 'POST Tell Rhythm',
    parameters: {
      httpMethod: 'POST',
      path: 'rhythm-agent/conversation',
      authentication: 'none',
      responseMode: 'lastNode',
      responseData: 'firstEntryJson',
      options: {
        allowedOrigins: '*',
        responseHeaders: { entries: [
          { name: 'Content-Type', value: 'application/json; charset=utf-8' },
          { name: 'Access-Control-Allow-Origin', value: '*' },
        ] },
      },
    },
  },
});

const normalize = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Validate Conversation Request', parameters: {
    mode: 'runOnceForAllItems', language: 'javaScript', jsCode: `
const input = $input.first().json;
const body = input.body || {};
const headers = input.headers || {};
const authorization = headers.authorization || headers.Authorization;
const supabaseKey = headers['x-supabase-key'] || headers['X-Supabase-Key'];
const date = String(body.date || '');
const message = typeof body.message === 'string' ? body.message.trim().slice(0, 500) : '';
if (!authorization || !String(authorization).startsWith('Bearer ')) throw new Error('A Supabase user session is required.');
if (!supabaseKey) throw new Error('Missing x-supabase-key header.');
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)) throw new Error('date must use YYYY-MM-DD.');
if (!message) throw new Error('Tell Rhythm what is going on first.');
return [{ json: {
  date, message,
  headers: { apikey: String(supabaseKey), Authorization: String(authorization) },
  stateBody: { p_action: 'get_state', p_date: date },
} }];
` } },
});

const loadState = node({
  type: 'n8n-nodes-base.httpRequest', version: 4.5,
  config: { name: 'Retrieve Current Rhythm State', parameters: {
    method: 'POST',
    url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_phase6_action',
    authentication: 'none', sendHeaders: true, specifyHeaders: 'keypair',
    headerParameters: { parameters: [
      { name: 'apikey', value: expr('{{ $json.headers.apikey }}') },
      { name: 'Authorization', value: expr('{{ $json.headers.Authorization }}') },
      { name: 'Content-Type', value: 'application/json' },
    ] },
    sendBody: true, contentType: 'json', specifyBody: 'json',
    jsonBody: expr('{{ JSON.stringify($json.stateBody) }}'),
    options: { timeout: 15000 },
  } },
});

const decisionSchema = '{"type":"object","additionalProperties":false,"required":["tool","chunkId","energyMode","effort","mealId","mood","guidance"],"properties":{"tool":{"type":"string","enum":["none","get_state","get_current_chunk","get_future_chunks","make_easier","change_energy","start_chunk","complete_chunk","meal_help","select_meal","snooze_transition","close_out"]},"chunkId":{"type":["string","null"]},"energyMode":{"type":["string","null"],"enum":["normal","low_energy","recovery","overwhelmed","momentum",null]},"effort":{"type":["string","null"],"enum":["no_cook","very_easy","cook_a_little",null]},"mealId":{"type":["string","null"]},"mood":{"type":["string","null"],"enum":["good","meh","hard",null]},"guidance":{"type":"string","maxLength":220}}}';

const chooseTool = node({
  type: '@n8n/n8n-nodes-langchain.openAi', version: 2.3,
  config: { name: 'Choose One Safe Rhythm Tool', credentials: { openAiApi: newCredential('OpenAI account') }, parameters: {
    resource: 'text', operation: 'response',
    modelId: { __rl: true, mode: 'id', value: 'gpt-5.4-mini', cachedResultName: 'GPT-5.4-MINI' },
    responses: { values: [
      { type: 'text', role: 'system', content: 'You are the private Rhythm Agent for one neurodivergent-friendly daily rhythm. Current state is always supplied. Choose zero or one safe tool—the smallest useful action. Never rebuild the day. Never invent calendar events, pantry items, meal IDs, chunk IDs, or context. A meeting or leave time mentioned by the user is information for brief guidance only; do not claim it was saved. Prefer none when no state change is needed. Exhaustion may justify change_energy to low_energy or recovery; do not overreact. “I do not want to cook” should use meal_help with no_cook. Hyperfocus should snooze only when a transitionPrompt exists; otherwise give guidance and preserve flow. Use make_easier only when reducing NOW/NEXT is useful. start_chunk requires an exact unfinished ID from state. complete_chunk is only for an explicit completion. select_meal requires an exact ID already present in mealChoices. close_out requires the user to state Good, Meh, or Hard; never guess mood. Keep guidance to one or two shame-free sentences and briefly say what will change or that nothing changed.' },
      { type: 'text', role: 'user', content: expr('{{ "User message: " + $("Validate Conversation Request").first().json.message + "\\nCurrent Rhythm state: " + JSON.stringify($("Retrieve Current Rhythm State").first().json) }}') },
    ] },
    simplify: true, builtInTools: {},
    options: { maxTokens: 450, store: false, temperature: 0.1,
      textFormat: { textOptions: { type: 'json_schema', name: 'rhythm_safe_tool_decision', schema: decisionSchema, description: 'At most one allowlisted Rhythm tool and a concise response.', strict: true } },
    },
  } },
});

const validateTool = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Validate Safe Tool Against State', parameters: {
    mode: 'runOnceForAllItems', language: 'javaScript', jsCode: `
const raw = $input.first().json;
let d = raw?.output?.[0]?.content?.[0]?.text ?? raw;
if (typeof d === 'string') { try { d = JSON.parse(d); } catch { d = {}; } }
if (!d || typeof d !== 'object' || Array.isArray(d)) d = {};
const request = $('Validate Conversation Request').first().json;
const state = $('Retrieve Current Rhythm State').first().json;
const allowed = new Set(['none','get_state','get_current_chunk','get_future_chunks','make_easier','change_energy','start_chunk','complete_chunk','meal_help','select_meal','snooze_transition','close_out']);
let tool = allowed.has(d.tool) ? d.tool : 'none';
let targetUrl = null;
let requestBody = null;
const chunks = Array.isArray(state.chunks) ? state.chunks : [];
const current = state.now || null;
const guidance = typeof d.guidance === 'string' && d.guidance.trim()
  ? d.guidance.trim().slice(0, 220)
  : 'I kept your rhythm where it is. Stay with the smallest useful next step.';

if (['get_state','get_current_chunk','get_future_chunks'].includes(tool)) tool = 'none';

if (tool === 'make_easier') {
  targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/adapt-day';
  requestBody = { date: request.date, note: request.message };
} else if (tool === 'change_energy') {
  if (!['normal','low_energy','recovery','overwhelmed','momentum'].includes(d.energyMode)) tool = 'none';
  else {
    targetUrl = 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_change_energy';
    requestBody = { p_date: request.date, p_energy_mode: d.energyMode };
  }
} else if (tool === 'start_chunk') {
  const target = chunks.find((chunk) => String(chunk.id) === String(d.chunkId));
  if (!target || ['completed','skipped'].includes(target.status)) tool = 'none';
  else {
    targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/action';
    requestBody = { action: 'start', date: request.date, chunkId: target.id };
  }
} else if (tool === 'complete_chunk') {
  if (!current?.id) tool = 'none';
  else {
    targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/action';
    requestBody = { action: 'complete', date: request.date };
  }
} else if (tool === 'meal_help') {
  const effort = ['no_cook','very_easy','cook_a_little'].includes(d.effort) ? d.effort : 'very_easy';
  targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/meal-help';
  requestBody = { action: 'meal_help', date: request.date, effort };
} else if (tool === 'select_meal') {
  const choices = Array.isArray(state.mealChoices) ? state.mealChoices : [];
  const meal = choices.find((choice) => String(choice.id) === String(d.mealId));
  if (!meal) tool = 'none';
  else {
    targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/meal-help';
    requestBody = { action: 'select_meal', date: request.date, mealId: meal.id };
  }
} else if (tool === 'snooze_transition') {
  if (!state.transitionPrompt?.id) tool = 'none';
  else {
    targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/action';
    requestBody = { action: 'snooze_prompt', date: request.date, promptId: state.transitionPrompt.id };
  }
} else if (tool === 'close_out') {
  if (!['good','meh','hard'].includes(d.mood)) tool = 'none';
  else {
    targetUrl = 'https://jagama.app.n8n.cloud/webhook/rhythm-agent/close-out-day';
    requestBody = { date: request.date, promptId: state.transitionPrompt?.type === 'close_out' ? state.transitionPrompt.id : null, mood: d.mood, note: request.message };
  }
}

return [{ json: {
  shouldAct: tool !== 'none' && Boolean(targetUrl), tool, guidance,
  headers: request.headers, targetUrl, requestBody, originalState: state,
} }];
` } },
});

const shouldAct = ifElse({ version: 2.3, config: { name: 'State Change Needed?', parameters: {
  conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 }, conditions: [{
    id: 'state-change', leftValue: expr('{{ $json.shouldAct }}'), rightValue: true,
    operator: { type: 'boolean', operation: 'equals' },
  }], combinator: 'and' },
} } });

const callSafeTool = node({
  type: 'n8n-nodes-base.httpRequest', version: 4.5,
  config: { name: 'Execute Allowlisted Rhythm Tool', parameters: {
    method: 'POST', url: expr('{{ $json.targetUrl }}'), authentication: 'none',
    sendHeaders: true, specifyHeaders: 'keypair', headerParameters: { parameters: [
      { name: 'apikey', value: expr('{{ $json.headers.apikey }}') },
      { name: 'Authorization', value: expr('{{ $json.headers.Authorization }}') },
      { name: 'x-supabase-key', value: expr('{{ $json.headers.apikey }}') },
      { name: 'Content-Type', value: 'application/json' },
    ] },
    sendBody: true, contentType: 'json', specifyBody: 'json',
    jsonBody: expr('{{ JSON.stringify($json.requestBody) }}'), options: { timeout: 60000 },
  } },
});

const formatChanged = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Explain Small Change', parameters: { mode: 'runOnceForAllItems', language: 'javaScript', jsCode: `
const state = $input.first().json;
const decision = $('Validate Safe Tool Against State').first().json;
const deterministic = state?.adaptation?.message || state?.agentChange?.message;
return [{ json: { ok: true, state, agent: {
  changed: true, action: decision.tool,
  message: deterministic || decision.guidance || 'I made the smallest useful change.',
} } }];
` } },
});

const formatGuidance = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Return Guidance Without Changing State', parameters: { mode: 'runOnceForAllItems', language: 'javaScript', jsCode: `
const decision = $input.first().json;
return [{ json: { ok: true, state: decision.originalState, agent: {
  changed: false, action: 'none', message: decision.guidance,
} } }];
` } },
});

export default workflow('rhythm-agent-conversation', 'Rhythm Agent — Conversation')
  .add(chatWebhook).to(normalize).to(loadState).to(chooseTool).to(validateTool).to(shouldAct)
  .onTrue(callSafeTool.to(formatChanged))
  .onFalse(formatGuidance);
