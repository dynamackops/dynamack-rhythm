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
      options: {
        allowedOrigins: '*',
      },
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
const allowed = ['get_state', 'complete', 'start'];

if (!allowed.includes(action)) {
  throw new Error('Unsupported Phase 1 action: ' + action);
}

const authorization = headers.authorization || headers.Authorization;
if (!authorization || !String(authorization).startsWith('Bearer ')) {
  throw new Error('A Supabase user session is required.');
}

const supabaseKey = headers['x-supabase-key'] || headers['X-Supabase-Key'];
if (!supabaseKey) {
  throw new Error('Missing x-supabase-key header.');
}

const date = String(body.date || '');
if (!/^\\d{4}-\\d{2}-\\d{2}$/.test(date)) {
  throw new Error('date must use YYYY-MM-DD.');
}

const projectUrl = 'https://yipznshcsgrqdzbcthjw.supabase.co';
const stateUrl = projectUrl
  + '/rest/v1/chunks'
  + '?select=id,daily_plan_id,template_key,title,position,status,transition_cue,ease_level,started_at,completed_at,daily_plans!inner(plan_date,energy_mode,status)'
  + '&daily_plans.plan_date=eq.' + encodeURIComponent(date)
  + '&order=position.asc';

return [{
  json: {
    action,
    date,
    chunkId: body.chunkId || null,
    stateUrl,
    headers: {
      apikey: String(supabaseKey),
      Authorization: String(authorization),
      'Content-Type': 'application/json',
    },
  },
}];
`,
    },
  },
});

const fetchStateBefore = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Fetch Current State',
    parameters: {
      method: 'GET',
      url: expr('{{ $json.stateUrl }}'),
      authentication: 'none',
      sendHeaders: true,
      specifyHeaders: 'json',
      jsonHeaders: expr('{{ $json.headers }}'),
      options: {
        timeout: 10000,
      },
    },
  },
});

const planMutations = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Plan Minimum State Changes',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const req = $('Normalize and Validate Action').first().json;
const rawItems = $input.all().map(item => item.json);
const rows = rawItems.length === 1 && Array.isArray(rawItems[0]) ? rawItems[0] : rawItems;
const activeRows = rows
  .filter(row => row && row.id)
  .sort((a, b) => Number(a.position) - Number(b.position));

const baseHeaders = {
  ...req.headers,
  Prefer: 'return=minimal',
};
const tableUrl = 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/chunks';
const patch = (url, body) => ({ json: { method: 'PATCH', url, body, headers: baseHeaders } });

if (req.action === 'get_state') {
  return [patch(tableUrl + '?id=eq.00000000-0000-0000-0000-000000000000', {
    updated_at: new Date().toISOString(),
  })];
}

if (!activeRows.length) {
  throw new Error('No plan exists for this date yet. Sign in through the dashboard to initialize it.');
}

if (req.action === 'complete') {
  const current = activeRows.find(row => row.status === 'current');
  if (!current) throw new Error('There is no current chunk to complete.');

  const next = activeRows.find(row => row.status === 'next');
  const following = next
    ? activeRows.find(row => row.status === 'later' && Number(row.position) > Number(next.position))
    : null;
  const now = new Date().toISOString();
  const mutations = [
    patch(tableUrl + '?id=eq.' + encodeURIComponent(current.id), {
      status: 'completed', completed_at: now, updated_at: now,
    }),
  ];
  if (next) {
    mutations.push(patch(tableUrl + '?id=eq.' + encodeURIComponent(next.id), {
      status: 'current', started_at: now, updated_at: now,
    }));
  }
  if (following) {
    mutations.push(patch(tableUrl + '?id=eq.' + encodeURIComponent(following.id), {
      status: 'next', updated_at: now,
    }));
  }
  return mutations;
}

const selected = activeRows.find(row => row.id === req.chunkId && row.status !== 'completed' && row.status !== 'skipped');
if (!selected) throw new Error('Select an unfinished chunk to start.');

const following = activeRows.find(row =>
  row.id !== selected.id
  && row.status !== 'completed'
  && row.status !== 'skipped'
  && Number(row.position) > Number(selected.position)
);
const now = new Date().toISOString();
const planId = selected.daily_plan_id;
const mutations = [
  patch(tableUrl + '?daily_plan_id=eq.' + encodeURIComponent(planId) + '&status=in.(current,next,later)', {
    status: 'later', updated_at: now,
  }),
  patch(tableUrl + '?id=eq.' + encodeURIComponent(selected.id), {
    status: 'current', started_at: now, updated_at: now,
  }),
];
if (following) {
  mutations.push(patch(tableUrl + '?id=eq.' + encodeURIComponent(following.id), {
    status: 'next', updated_at: now,
  }));
}
return mutations;
`,
    },
  },
});

const applyMutations = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Apply State Changes Sequentially',
    parameters: {
      method: expr('{{ $json.method }}'),
      url: expr('{{ $json.url }}'),
      authentication: 'none',
      sendHeaders: true,
      specifyHeaders: 'json',
      jsonHeaders: expr('{{ $json.headers }}'),
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: expr('{{ $json.body }}'),
      options: {
        batching: {
          batch: {
            batchSize: 1,
            batchInterval: 0,
          },
        },
        timeout: 10000,
      },
    },
  },
});

const prepareFinalRead = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Final State Read',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const req = $('Normalize and Validate Action').first().json;
return [{ json: { stateUrl: req.stateUrl, headers: req.headers, action: req.action, date: req.date } }];
`,
    },
  },
});

const fetchStateAfter = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Fetch Updated State',
    parameters: {
      method: 'GET',
      url: expr('{{ $json.stateUrl }}'),
      authentication: 'none',
      sendHeaders: true,
      specifyHeaders: 'json',
      jsonHeaders: expr('{{ $json.headers }}'),
      options: {
        timeout: 10000,
      },
    },
  },
});

const formatState = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Format NOW NEXT LATER',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
const req = $('Normalize and Validate Action').first().json;
const rawItems = $input.all().map(item => item.json);
const rows = (rawItems.length === 1 && Array.isArray(rawItems[0]) ? rawItems[0] : rawItems)
  .filter(row => row && row.id)
  .sort((a, b) => Number(a.position) - Number(b.position));
const plan = rows[0] && rows[0].daily_plans ? rows[0].daily_plans : null;
return [{
  json: {
    ok: true,
    action: req.action,
    date: req.date,
    needsSetup: rows.length === 0,
    energyMode: plan ? plan.energy_mode : 'normal',
    now: rows.find(row => row.status === 'current') || null,
    next: rows.find(row => row.status === 'next') || null,
    later: rows.filter(row => row.status === 'later'),
    completed: rows.filter(row => row.status === 'completed'),
    chunks: rows,
  },
}];
`,
    },
  },
});

const respond = node({
  type: 'n8n-nodes-base.respondToWebhook',
  version: 1.5,
  config: {
    name: 'Return Dashboard State',
    parameters: {
      respondWith: 'json',
      responseBody: expr('{{ $json }}'),
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

export default workflow('rhythm-agent-router-phase-1', 'Rhythm Agent Router — Phase 1')
  .add(actionWebhook)
  .to(normalizeRequest)
  .to(fetchStateBefore)
  .to(planMutations)
  .to(applyMutations)
  .to(prepareFinalRead)
  .to(fetchStateAfter)
  .to(formatState)
  .to(respond);
