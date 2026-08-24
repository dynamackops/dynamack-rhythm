import { workflow, node, trigger, newCredential, expr } from '@n8n/workflow-sdk';

const transitionSchedule = trigger({
  type: 'n8n-nodes-base.scheduleTrigger',
  version: 1.3,
  config: {
    name: 'Every 10 Minutes Eastern',
    parameters: {
      rule: {
        interval: [{ field: 'minutes', minutesInterval: 10 }],
      },
    },
  },
});

const prepareCheck = node({
  type: 'n8n-nodes-base.code',
  version: 2,
  config: {
    name: 'Prepare Gentle Transition Check',
    parameters: {
      mode: 'runOnceForAllItems',
      language: 'javaScript',
      jsCode: `
return [{ json: {
  rpcBody: {
    p_owner_email: '__RHYTHM_OWNER_EMAIL__'
  }
} }];
`,
    },
  },
});

const surfaceDuePrompt = node({
  type: 'n8n-nodes-base.httpRequest',
  version: 4.5,
  config: {
    name: 'Surface One Due Suggestion',
    credentials: { httpHeaderAuth: newCredential('Rhythm Supabase Service') },
    parameters: {
      method: 'POST',
      url: 'https://yipznshcsgrqdzbcthjw.supabase.co/rest/v1/rpc/rhythm_surface_due_prompts',
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
      options: { timeout: 10000 },
    },
  },
});

export default workflow('rhythm-agent-chunk-transition', 'Rhythm Agent — Chunk Transition')
  .add(transitionSchedule)
  .to(prepareCheck)
  .to(surfaceDuePrompt);
