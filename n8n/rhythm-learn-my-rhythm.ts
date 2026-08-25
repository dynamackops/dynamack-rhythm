import { workflow, node, trigger, newCredential, ifElse, expr } from '@n8n/workflow-sdk';

const learnWebhook = trigger({
  type: 'n8n-nodes-base.webhook', version: 2.1,
  config: { name: 'POST Learn My Rhythm', parameters: {
    httpMethod: 'POST', path: 'rhythm-agent/learn', authentication: 'none',
    responseMode: 'lastNode', responseData: 'firstEntryJson',
    options: { allowedOrigins: '*', responseHeaders: { entries: [
      { name: 'Content-Type', value: 'application/json; charset=utf-8' },
      { name: 'Access-Control-Allow-Origin', value: '*' },
    ] } },
  } },
});

const normalize = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Validate Learning Request', parameters: { mode: 'runOnceForAllItems', language: 'javaScript', jsCode: `
const input = $input.first().json;
const headers = input.headers || {};
const authorization = headers.authorization || headers.Authorization;
const supabaseKey = headers['x-supabase-key'] || headers['X-Supabase-Key'];
const requested = Number(input.body?.windowDays || 28);
if (!authorization || !String(authorization).startsWith('Bearer ')) throw new Error('A Supabase user session is required.');
if (!supabaseKey) throw new Error('Missing x-supabase-key header.');
const windowDays = Math.max(14, Math.min(Number.isFinite(requested) ? Math.round(requested) : 28, 28));
return [{ json: {
  headers: { apikey: String(supabaseKey), Authorization: String(authorization) },
  rpcBody: { p_days: windowDays },
} }];
` } },
});

const loadAggregates = node({
  type: 'n8n-nodes-base.httpRequest', version: 4.5,
  config: { name: 'Calculate Deterministic Patterns', parameters: {
    method: 'POST', url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_learning_context_v2',
    authentication: 'none', sendHeaders: true, specifyHeaders: 'keypair',
    headerParameters: { parameters: [
      { name: 'apikey', value: expr('{{ $json.headers.apikey }}') },
      { name: 'Authorization', value: expr('{{ $json.headers.Authorization }}') },
      { name: 'Content-Type', value: 'application/json' },
    ] },
    sendBody: true, contentType: 'json', specifyBody: 'json',
    jsonBody: expr('{{ JSON.stringify($json.rpcBody) }}'), options: { timeout: 15000 },
  } },
});

const hasPatterns = ifElse({ version: 2.3, config: { name: 'Enough Supported Patterns?', parameters: {
  conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict', version: 2 }, conditions: [{
    id: 'supported-patterns',
    leftValue: expr('{{ $json.ready === true && Array.isArray($json.patterns) && $json.patterns.length > 0 }}'),
    rightValue: true, operator: { type: 'boolean', operation: 'equals' },
  }], combinator: 'and' },
} } });

const insightSchema = '{"type":"object","additionalProperties":false,"required":["headline","insights"],"properties":{"headline":{"type":"string","maxLength":100},"insights":{"type":"array","minItems":1,"maxItems":3,"items":{"type":"object","additionalProperties":false,"required":["patternId","body","smallStep"],"properties":{"patternId":{"type":"string"},"body":{"type":"string","maxLength":180},"smallStep":{"type":"string","maxLength":140}}}}}}';

const summarize = node({
  type: '@n8n/n8n-nodes-langchain.openAi', version: 2.3,
  config: { name: 'Summarize Supported Patterns Only', credentials: { openAiApi: newCredential('OpenAI account') }, parameters: {
    resource: 'text', operation: 'response',
    modelId: { __rl: true, mode: 'id', value: 'gpt-5.4-mini', cachedResultName: 'GPT-5.4-MINI' },
    responses: { values: [
      { type: 'text', role: 'system', content: 'Summarize only the supplied deterministic Rhythm patterns. Every insight must cite one exact patternId from the input. Do not calculate new correlations, diagnose the user, use productivity language, percentages, streaks, scores, red flags, or failure framing. Keep it gentle, practical, and focused on what seems to support this person’s brain. At most three insights.' },
      { type: 'text', role: 'user', content: expr('{{ "Supported patterns: " + JSON.stringify($("Calculate Deterministic Patterns").first().json.patterns) }}') },
    ] },
    simplify: true, builtInTools: {},
    options: { maxTokens: 550, store: false, temperature: 0.2,
      textFormat: { textOptions: { type: 'json_schema', name: 'rhythm_supported_insights', schema: insightSchema, description: 'Gentle insights tied to exact deterministic pattern IDs.', strict: true } },
    },
  } },
});

const validateSummary = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Validate Insight Evidence', parameters: { mode: 'runOnceForAllItems', language: 'javaScript', jsCode: `
const raw = $input.first().json;
let ai = raw?.output?.[0]?.content?.[0]?.text ?? raw;
if (typeof ai === 'string') { try { ai = JSON.parse(ai); } catch { ai = {}; } }
const context = $('Calculate Deterministic Patterns').first().json;
const evidence = new Map((context.patterns || []).map((p) => [String(p.id), p]));
const insights = [];
for (const item of Array.isArray(ai?.insights) ? ai.insights.slice(0, 3) : []) {
  const pattern = evidence.get(String(item?.patternId || ''));
  if (!pattern) continue;
  insights.push({
    patternId: pattern.id,
    kind: pattern.kind,
    body: String(item.body || '').trim().slice(0, 180),
    smallStep: String(item.smallStep || '').trim().slice(0, 140),
  });
}
return [{ json: { ok: true, learning: {
  ready: true,
  observedDays: context.observedDays,
  windowDays: context.windowDays,
  headline: String(ai?.headline || 'Your rhythm lately').trim().slice(0, 100),
  insights,
} } }];
` } },
});

const stillLearning = node({
  type: 'n8n-nodes-base.code', version: 2,
  config: { name: 'Return Still Learning Gently', parameters: { mode: 'runOnceForAllItems', language: 'javaScript', jsCode: `
const context = $input.first().json;
const remaining = Math.max(0, Number(context.minimumDays || 3) - Number(context.observedDays || 0));
return [{ json: { ok: true, learning: {
  ready: false,
  observedDays: context.observedDays || 0,
  windowDays: context.windowDays || 28,
  headline: 'Still learning your rhythm',
  message: remaining > 0
    ? 'Close out ' + remaining + ' more day' + (remaining === 1 ? '' : 's') + ' before I look for patterns. I will wait for real evidence.'
    : 'There is enough history, but no pattern is strong enough to call useful yet.',
  insights: [],
} } }];
` } },
});

export default workflow('rhythm-agent-learn-my-rhythm', 'Rhythm Agent — Learn My Rhythm')
  .add(learnWebhook).to(normalize).to(loadAggregates).to(hasPatterns)
  .onTrue(summarize.to(validateSummary))
  .onFalse(stillLearning);
