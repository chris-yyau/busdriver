// scripts/hooks/ultra-oracle-child/j-get.js — spec §5 J-get. Binds, then downloads uora-<tag>.json and returns SAVED.
(async () => {
  try {
    if (location.origin !== 'https://chatgpt.com') return 'ERR origin';
    // ---- uora fetch helpers (identical in j-poll, j-get, j-archive) ----
    const T0 = Date.now(), BUDGET = 38000;
    const fail = (tok) => { throw { tok }; };
    const httpErr = (s) => (s === 401 || s === 403) ? 'ERR auth ' + s : s === 404 ? 'ERR gone'
      : s === 408 ? 'ERR timeout' : s === 429 ? 'ERR rate ' + s
      : (s >= 400 && s < 500) ? 'ERR schema ' + s : (s >= 500 && s < 600) ? 'ERR server ' + s : 'ERR schema ' + s;
    const call = async (url, init, wantJson) => {
      const left = BUDGET - (Date.now() - T0);
      if (left <= 0) fail('ERR timeout');
      const ac = new AbortController();
      const t = setTimeout(() => ac.abort(), Math.min(10000, left));
      try {
        let r;
        try { r = await fetch(url, Object.assign({ signal: ac.signal }, init)); } catch (e) { fail(ac.signal.aborted ? 'ERR timeout' : 'ERR network'); }
        if (r.status !== 200) fail(wantJson ? httpErr(r.status) : 'ERR archive ' + r.status);
        if (!wantJson) return null;
        try { return await r.json(); } catch (e) { fail(ac.signal.aborted ? 'ERR timeout' : 'ERR schema'); }
      } finally { clearTimeout(t); }
    };
    const idOf = () => { const m = /^\/c\/([0-9a-f-]{36})$/.exec(location.pathname); if (!m) fail('ERR binding'); return m[1]; };
    const session = async () => {
      const s = await call('/api/auth/session', {}, true);
      if (!s || typeof s.accessToken !== 'string' || !s.accessToken) fail('ERR auth');
      return s.accessToken;
    };
    const tree = async (id, tok) => {
      const j = await call('/backend-api/conversation/' + id, { headers: { Authorization: 'Bearer ' + tok } }, true);
      if (!j || typeof j !== 'object' || !j.mapping || typeof j.mapping !== 'object' || typeof j.current_node !== 'string') fail('ERR schema');
      const node = j.mapping[j.current_node];
      const nm = node && node.message;
      if (!nm || typeof nm !== 'object' || !nm.author || typeof nm.author.role !== 'string'
        || !nm.content || typeof nm.content.content_type !== 'string') fail('ERR schema');
      return j;
    };
    const fin = (m) => !!m && !!m.author && m.author.role === 'assistant' && !!m.content
      && m.content.content_type === 'text' && m.status === 'finished_successfully' && m.end_turn === true;
    const visible = (m) => !!m && !!m.author && (m.author.role === 'user' || m.author.role === 'assistant') && !!m.content
      && (m.content.content_type === 'text' || m.content.content_type === 'multimodal_text')
      && !(m.metadata && m.metadata.is_visually_hidden_from_conversation === true);
    const userTurn = (j) => { // first visible user ancestor; no other visible turn above it (fresh conversation)
      const seen = new Set(); let p = j.mapping[j.current_node].parent, uid = null;
      for (;;) { // only an explicit null parent ends the walk; a missing parent is malformed, not a root
        if (p === null) break;
        if (typeof p !== 'string' || seen.has(p) || !j.mapping[p]) fail('ERR schema');
        seen.add(p);
        const m = j.mapping[p].message;
        if (uid === null) { if (visible(m) && m.author.role === 'user') uid = p; } else if (visible(m)) fail('ERR binding');
        p = j.mapping[p].parent;
      }
      if (uid === null) fail('ERR binding');
      return uid;
    };
    const attached = (j, uid, name) => {
      const a = (j.mapping[uid].message.metadata || {}).attachments || [];
      if (!Array.isArray(a)) fail('ERR schema');
      if (!a.some((x) => x && x.name === name)) fail('ERR binding');
    };
    // ---- end uora fetch helpers ----
    const TAG = '__UORA_TAG__', NAME = 'uora-' + TAG + '.txt';
    const id = idOf(); const j = await tree(id, await session());
    const msg = j.mapping[j.current_node].message;
    if (!fin(msg)) fail('ERR binding');
    const model = (msg.metadata || {}).model_slug;
    if (typeof model !== 'string' || !/^gpt-[0-9]+(\.[0-9]+)*-pro$/.test(model)) fail('ERR binding');
    const uid = userTurn(j); attached(j, uid, NAME);
    const parts = msg.content.parts;
    if (!Array.isArray(parts) || parts.some((p) => typeof p !== 'string')) fail('ERR schema');
    const obj = { tag: TAG, id, user_message_id: uid, assistant_message_id: j.current_node, role: 'assistant',
      content_type: 'text', status: msg.status, end_turn: true, model, attachment: NAME, text: parts.join('') };
    const bytes = new TextEncoder().encode(JSON.stringify(obj));
    const dig = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
    const hex = Array.from(dig, (b) => b.toString(16).padStart(2, '0')).join('');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([bytes], { type: 'application/json' })); // never revoked synchronously (§5)
    a.download = 'uora-' + TAG + '.json';
    document.body.appendChild(a); a.click(); a.remove();
    return 'SAVED ' + bytes.length + ' ' + hex;
  } catch (e) {
    return (e && typeof e.tok === 'string' && /^ERR [a-z0-9_-]+( [0-9]{3})?$/.test(e.tok)) ? e.tok : 'ERR schema';
  }
})()
