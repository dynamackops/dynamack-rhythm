// Credentials stay in Rhythm. Only a small dashboard summary crosses origins.
export const COSMO_ORIGIN = 'https://jasmine-jarvis.netlify.app';

export function summarizeRhythm(state) {
  if (!state) return null;
  const chunk = (value) => value ? {
    title: String(value.title || '').slice(0, 120),
    cue: String(value.transition_cue || '').slice(0, 500),
  } : null;
  return {
    date: state.date, energyMode: state.energyMode,
    needsSetup: Boolean(state.needsSetup), closed: Boolean(state.closeOut?.closed),
    now: chunk(state.now), next: chunk(state.next),
  };
}

export function installCosmoBridge({ host = window, getSession, getState, refresh, converse }) {
  let peer = null;
  let channel = null;
  let pending = false;
  const seen = new Set();
  function publish() {
    if (!peer || peer.closed) return;
    peer.postMessage({ type: 'rhythm:state', channel,
      signedIn: Boolean(getSession()),
      state: getSession() ? summarizeRhythm(getState()) : null,
    }, COSMO_ORIGIN);
  }
  const receive = async (event) => {
    const data = event.data;
    if (event.origin !== COSMO_ORIGIN || !host.opener || event.source !== host.opener ||
        !data || typeof data !== 'object') return;
    if (data.type === 'cosmo:connect') {
      if (typeof data.channel !== 'string' || !/^[a-zA-Z0-9-]{16,80}$/.test(data.channel)) return;
      if (channel !== data.channel) seen.clear();
      peer = event.source;
      channel = data.channel;
      publish();
      return;
    }
    if (!peer || data.channel !== channel || data.type !== 'cosmo:request' ||
        typeof data.id !== 'string' || !/^[a-zA-Z0-9-]{16,80}$/.test(data.id) || seen.has(data.id)) return;
    const requestPeer = peer;
    const requestChannel = channel;
    const reply = (result) => requestPeer.postMessage({ type: 'rhythm:reply', channel: requestChannel, id: data.id, ...result }, COSMO_ORIGIN);
    if (!['get_state', 'conversation'].includes(data.action)) return reply({ ok: false, error: 'Unsupported request.' });
    if (!getSession()) return reply({ ok: false, error: 'Sign in to Rhythm in the connected tab first.' });
    if (pending) return reply({ ok: false, error: 'Rhythm is finishing your previous request.' });
    if (data.action === 'conversation' && (typeof data.message !== 'string' || !data.message.trim() || data.message.length > 500)) {
      return reply({ ok: false, error: 'Use a message between 1 and 500 characters.' });
    }
    seen.add(data.id);
    if (seen.size > 200) seen.delete(seen.values().next().value);
    pending = true;
    const ownerId = getSession()?.user?.id;
    try {
      const message = data.action === 'conversation' ? await converse(data.message.trim()) : (await refresh(), '');
      if (!getSession() || getSession()?.user?.id !== ownerId) {
        reply({ ok: false, error: 'Your Rhythm session changed. Reconnect before continuing.' });
        publish();
        return;
      }
      reply({ ok: true, message, state: summarizeRhythm(getState()) });
      publish();
    } catch (error) {
      reply({ ok: false, error: error.message || 'Rhythm could not complete that request.' });
    } finally { pending = false; }
  };
  host.addEventListener('message', receive);
  return { publish, dispose: () => host.removeEventListener('message', receive) };
}
