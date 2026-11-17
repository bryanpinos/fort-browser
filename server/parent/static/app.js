const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const when = t => { if (!t) return '—'; const d = typeof t === 'number' ? new Date(t * 1000) : new Date(t); return d.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }); };
let kids = [], current = null, tab = 'browsing';
async function api(path) { const r = await fetch(path); if (r.status === 401) { location.href = '/login'; throw new Error('signed out'); } if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || 'Couldn’t load'); return r.json(); }
async function loadKids() {
  kids = await api('/api/kids');
  $('#kids').innerHTML = kids.map(k => `<div class="card kid ${current === k.id ? 'sel' : ''}" data-id="${esc(k.id)}"><h2>${esc(k.name)}</h2><div class="stats">
    <span>Sites today<br><b>${k.visits_24h}</b></span><span>Blocked today<br><b>${k.blocked_24h ? '⛔ ' + k.blocked_24h : '0'}</b></span>
    <span>Flagged (7 days)<br><b>${k.flagged_7d ? '⚠️ ' + k.flagged_7d : '✓ 0'}</b></span><span>Fort Chat chats<br><b>${k.chats ?? '?'}</b></span></div>
    <p class="muted" style="margin:8px 0 0;font-size:12px">${k.default_browser === 'yes' ? '✓ Fort is the default browser' : k.default_browser === 'no' ? '⚠️ Fort is not the default browser' : 'Default browser: not reported yet'}${k.app_version ? ' · build ' + esc(k.app_version) : ''}<br>Last seen ${when(k.last_seen)}</p></div>`).join('');
  document.querySelectorAll('.kid').forEach(el => el.onclick = () => { current = el.dataset.id; loadKids(); show(); });
}
async function show() {
  if (!current) return;
  const k = kids.find(x => x.id === current);
  $('#detail').innerHTML = `<div class="tabs"><button data-t="browsing" class="${tab === 'browsing' ? 'on' : ''}">Browsing</button><button data-t="chats" class="${tab === 'chats' ? 'on' : ''}">Fort Chat</button></div><div id="pane" class="muted">Loading…</div>`;
  document.querySelectorAll('#detail .tabs button').forEach(b => b.onclick = () => { tab = b.dataset.t; show(); });
  try { tab === 'browsing' ? await showBrowsing(k) : await showChats(k); } catch (e) { $('#pane').textContent = e.message; }
}
async function showBrowsing(k) {
  $('#pane').innerHTML = `<div class="filters"><select id="days"><option value="1">Today</option><option value="7" selected>7 days</option><option value="30">30 days</option></select>
    <select id="what"><option value="all">Everything</option><option value="blocked">Blocked only</option><option value="flagged">Flagged only</option></select></div><div id="rows">Loading…</div>`;
  const render = async () => {
    const rows = await api(`/api/kids/${k.id}/browsing?days=${$('#days').value}`), what = $('#what').value;
    const shown = rows.filter(r => what === 'all' || (what === 'blocked' ? r.allowed === 0 : (r.concern ?? 0) >= 2));
    $('#rows').innerHTML = shown.length ? `<table><tr><th>When</th><th>Site</th><th>What happened</th></tr>${shown.map(r => {
      const status = r.kind === 'page' ? (r.status === 'done' ? ((r.concern ?? 0) >= 2 ? `<span class="tag flag">⚠️ ${esc(r.category)}</span> ` : `<span class="tag ok">✓ ${esc(r.category || 'ok')}</span> `) + `<span class="muted">${esc(r.summary)}</span>` : '<span class="muted">page read, not reviewed</span>')
        : (r.allowed === 0 ? `<span class="tag blocked">⛔ blocked</span> <span class="muted">${esc(r.reason)}</span>` : '<span class="tag ok">✓ visited</span>');
      return `<tr><td class="muted" style="white-space:nowrap">${when(r.ts)}</td><td><div class="host">${esc(r.host)}</div><div class="muted" style="font-size:12px">${esc((r.title || r.url || '').slice(0, 90))}</div></td><td>${status}</td></tr>`; }).join('')}</table>` : '<p class="muted">Nothing here.</p>';
  };
  $('#days').onchange = $('#what').onchange = render; await render();
}
async function showChats(k) {
  const list = await api(`/api/kids/${k.id}/chats`);
  $('#pane').innerHTML = list.length ? `<table><tr><th>Chat</th><th>Last message</th></tr>${list.map(c => `<tr><td><a href="#" data-c="${esc(c.id)}">${esc(c.title || 'Untitled')}</a></td><td class="muted">${when(c.updated_at)}</td></tr>`).join('')}</table><div id="chat"></div>` : '<p class="muted">No chats yet.</p>';
  document.querySelectorAll('[data-c]').forEach(a => a.onclick = async e => { e.preventDefault(); const c = await api(`/api/kids/${k.id}/chats/${a.dataset.c}`);
    $('#chat').innerHTML = `<div class="card" style="margin-top:14px"><h3 style="margin-top:0">${esc(c.title)}</h3>${c.messages.map(m => `<div class="msg ${m.role === 'user' ? 'user' : 'assistant'}">${esc(m.content)}${m.images ? `<div style="font-size:12px;opacity:.8">📷 ${m.images} photo(s)</div>` : ''}</div>`).join('')}</div>`; $('#chat').scrollIntoView({ behavior: 'smooth' }); });
}
$('#refresh').onclick = () => { loadKids(); show(); };
$('#logout').onclick = async () => { await fetch('/auth/logout', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' }); location.href = '/login'; };
loadKids().then(() => { if (kids.length) { current = kids[0].id; loadKids(); show(); } });
