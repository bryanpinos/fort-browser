// Settings: the home config the relay serves to the iPads.
const S = { state: null, scope: 'everyone' };
const FIELDS = [
  { key: 'favorites', title: 'Favorites', hint: 'Tiles on the start page. Kids’ own starred favorites stay too.' },
  { key: 'denylist', title: 'Blocked sites', hint: 'One site per line, e.g. youtube.com. Subdomains are blocked too.' },
  { key: 'allowlist', title: 'Only allow these sites', hint: 'Leave empty to allow everything else. If you list any, ONLY these open.' },
  { key: 'homeURL', title: 'Home page', hint: 'Where the house button goes.' },
  { key: 'reviewPages', title: 'Page review', hint: 'Send each page’s text home for Gemma to review and flag.' },
  { key: 'enforceSafeSearch', title: 'Strict SafeSearch', hint: 'Force strict mode on Google, Bing and DuckDuckGo.' },
  { key: 'searchEngine', title: 'Search engine', hint: 'Where searches typed in the address bar go. Google if not set.' },
  { key: 'appLinks', title: 'Apps pages may open', hint: 'Some sites hand off to their app, like Roblox after signing in. One per line, e.g. roblox. Fort asks the kid before opening one.' },
  { key: 'parentPINHash', title: 'Parent PIN', hint: 'The PIN for Parent settings on the iPad. Only a hash is stored.' },
];
const hostOf = s => { s = s.trim().toLowerCase(); if (!s) return ''; try { return new URL(s.includes('://') ? s : 'https://' + s).hostname.replace(/^www\./, 'www.'); } catch { return s; } };
const ENGINES = { google: 'Google', bing: 'Bing', duckduckgo: 'DuckDuckGo' };
// Same list as the app's AppLinks.neverAllowed: other browsers, Shortcuts, Settings, installs.
const NEVER_APPS = new Set(['x-safari-http', 'x-safari-https', 'com-apple-mobilesafari-tab', 'x-web-search', 'googlechrome', 'googlechromes', 'googlechrome-x-callback', 'firefox', 'firefox-focus', 'fennec', 'microsoft-edge', 'microsoft-edge-http', 'microsoft-edge-https', 'opera-http', 'opera-https', 'brave', 'ddgquicklink', 'duckduckgo', 'onionhttp', 'onionhttps', 'orion', 'arc', 'ecosia', 'kagi', 'shortcuts', 'workflow', 'prefs', 'app-prefs', 'app-settings', 'itms', 'itms-apps', 'itms-appss', 'itms-services', 'itms-beta', 'macappstore']);
const appScheme = s => s.trim().toLowerCase().replace(/:(\/\/)?$/, '');
const validTemplate = s => { try { const u = new URL(s.replace('%s', 'q')); return u.protocol === 'https:' && !!u.hostname && s.includes('%s'); } catch { return false; } };
const urlOf = s => { s = s.trim(); return s && !s.includes('://') ? 'https://' + s : s; };
async function sha256(t) { const b = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(t)); return [...new Uint8Array(b)].map(x => x.toString(16).padStart(2, '0')).join(''); }

function summary(key, v) {
  if (v === undefined) return 'each iPad’s own setting';
  if (key === 'favorites') return v.map(f => f.name).join(', ') || 'none';
  if (key === 'denylist' || key === 'allowlist') return v.length ? v.join(', ') : 'none';
  if (key === 'parentPINHash') return 'a PIN is set';
  if (typeof v === 'boolean') return v ? 'on' : 'off';
  if (key === 'searchEngine') return ENGINES[v] || v;
  if (key === 'appLinks') return v.length ? v.join(', ') : 'none';
  return String(v);
}
function editor(key, v) {
  if (key === 'favorites') return `<div id="favs">${(v || []).map(favRow).join('')}</div><button data-addfav>+ Add favorite</button>`;
  if (key === 'appLinks') return `<textarea rows="3" data-k="appLinks" placeholder="roblox">${esc((v || []).join('\n'))}</textarea><p class="hint">Fort never opens other browsers, Shortcuts, Settings or the App Store.</p>`;
  if (key === 'denylist' || key === 'allowlist') return `<textarea rows="5" data-k="${key}">${esc((v || []).join('\n'))}</textarea>${key === 'allowlist' ? '<p class="warn" data-allowwarn hidden>⚠️ Only the sites listed here will open.</p>' : ''}`;
  if (key === 'homeURL') return `<input type="url" data-k="homeURL" value="${esc(v || 'https://')}">`;
  if (key === 'searchEngine') { const custom = v && !ENGINES[v];
    return `<select data-k="engine">${Object.entries(ENGINES).map(([k, n]) => `<option value="${k}" ${(v || 'google') === k ? 'selected' : ''}>${n}</option>`).join('')}<option value="custom" ${custom ? 'selected' : ''}>Custom…</option></select>
      <div data-custom ${custom ? '' : 'hidden'}><input type="url" data-k="template" placeholder="https://search.example.com/search?q=%s" value="${esc(custom ? v : '')}">
      <p class="hint">An https address with <code>%s</code> where the search words go.</p>
      <p class="warn">⚠️ Fort can’t force SafeSearch on a custom search engine. Pick one that filters results itself, or block adult sites at home.</p></div>`; }
  if (key === 'parentPINHash') return `<input type="password" inputmode="numeric" data-k="pin" placeholder="${v ? 'Leave blank to keep the current PIN' : 'New PIN (4–8 digits)'}" data-has="${v ? 1 : 0}">`;
  return `<label class="switch" style="margin:0"><input type="checkbox" data-k="${key}" ${v ? 'checked' : ''}> ${key === 'reviewPages' ? 'Review pages' : 'Strict'}</label>`;
}
const favRow = f => `<div class="fav"><input type="text" placeholder="Name" value="${esc(f?.name || '')}" maxlength="40"><input type="url" placeholder="pbskids.org" value="${esc(f?.url || '')}"><button data-rmfav>✕</button></div>`;

function render() {
  const st = S.state, everyone = st.everyone, isKid = S.scope !== 'everyone';
  const mine = isKid ? (st.kids[S.scope] || {}) : everyone, name = isKid ? st.kidNames[S.scope] : 'all iPads';
  $('#settings').innerHTML = `<div class="tabs"><button data-scope="everyone" class="${!isKid ? 'on' : ''}">Everyone</button>${Object.entries(st.kidNames).map(([id, n]) => `<button data-scope="${id}" class="${S.scope === id ? 'on' : ''}">${esc(n)}</button>`).join('')}</div>
    <p class="muted">${isKid ? `Settings that are different for ${esc(name)}. Everything else comes from <b>Everyone</b>.` : 'Settings for every iPad. Turn a setting off to leave it to each iPad’s own Parent settings.'} iPads pick up changes within 15 minutes.</p>
    ${FIELDS.map(f => { const has = Object.prototype.hasOwnProperty.call(mine, f.key);
      return `<div class="card sect ${has ? '' : 'off'}" data-field="${f.key}"><h3>${f.title}<label class="switch"><input type="checkbox" data-on ${has ? 'checked' : ''}> ${isKid ? 'Different for ' + esc(name) : 'Set for all iPads'}</label></h3>
        <p class="hint">${f.hint}${isKid && !has ? ` Now: <b>${esc(summary(f.key, everyone[f.key]))}</b> (from Everyone).` : ''}</p><div class="body">${editor(f.key, has ? mine[f.key] : (isKid ? everyone[f.key] : undefined))}</div></div>`; }).join('')}
    <div class="savebar"><button class="primary" id="save">Save</button><span id="msg" class="muted"></span></div>
    <div class="card" style="margin-top:14px"><h3 style="margin-top:0">Earlier versions</h3><ul class="hist" id="hist"><li class="muted">Loading…</li></ul></div>`;
  document.querySelectorAll('[data-scope]').forEach(b => b.onclick = () => { S.scope = b.dataset.scope; render(); });
  document.querySelectorAll('[data-on]').forEach(cb => cb.onchange = () => cb.closest('.sect').classList.toggle('off', !cb.checked));
  const favs = $('#favs'); if (favs) {
    $('[data-addfav]').onclick = () => { favs.insertAdjacentHTML('beforeend', favRow()); wireFavs(); };
    const wireFavs = () => document.querySelectorAll('[data-rmfav]').forEach(b => b.onclick = () => b.closest('.fav').remove()); wireFavs(); }
  const engine = document.querySelector('[data-k=engine]'); if (engine) engine.onchange = () => document.querySelector('[data-custom]').hidden = engine.value !== 'custom';
  const allow = document.querySelector('[data-k=allowlist]'); if (allow) { const w = () => document.querySelector('[data-allowwarn]').hidden = !allow.value.trim(); allow.oninput = w; w(); }
  $('#save').onclick = save; loadHistory();
}
async function collect() {
  const mine = S.scope === 'everyone' ? S.state.everyone : (S.state.kids[S.scope] || {}), out = {};
  for (const sect of document.querySelectorAll('.sect')) {
    const key = sect.dataset.field; if (!sect.querySelector('[data-on]').checked) continue;
    if (key === 'favorites') out.favorites = [...sect.querySelectorAll('.fav')].map(r => { const [n, u] = r.querySelectorAll('input'); return { name: n.value.trim(), url: urlOf(u.value) }; }).filter(f => f.name || f.url !== '');
    else if (key === 'denylist' || key === 'allowlist') out[key] = [...new Set(sect.querySelector('textarea').value.split(/[\n,]/).map(hostOf).filter(Boolean))];
    else if (key === 'searchEngine') { const choice = sect.querySelector('[data-k=engine]').value;
      if (choice !== 'custom') out.searchEngine = choice;
      else { const t = sect.querySelector('[data-k=template]').value.trim();
        if (!validTemplate(t)) throw new Error('The custom search engine needs an https address with %s where the search words go.'); out.searchEngine = t; } }
    else if (key === 'appLinks') { const apps = [...new Set(sect.querySelector('textarea').value.split(/[\n,]/).map(appScheme).filter(Boolean))];
      const bad = apps.filter(a => !/^[a-z][a-z0-9+.-]{0,63}$/.test(a) || ['http', 'https', 'about'].includes(a));
      const never = apps.filter(a => NEVER_APPS.has(a));
      if (bad.length) throw new Error(`Not an app link name: ${bad.join(', ')}. Use the part before "://", e.g. roblox.`);
      if (never.length) throw new Error(`Fort never opens ${never.join(', ')}.`);
      out.appLinks = apps; }
    else if (key === 'homeURL') out.homeURL = urlOf(sect.querySelector('.body input').value);
    else if (key === 'parentPINHash') { const pin = sect.querySelector('.body input').value.trim();
      if (pin) { if (!/^\d{4,8}$/.test(pin)) throw new Error('The PIN must be 4 to 8 digits.'); out.parentPINHash = await sha256(pin); }
      else if (mine.parentPINHash) out.parentPINHash = mine.parentPINHash; else throw new Error('Enter a PIN, or turn the Parent PIN setting off.'); }
    else out[key] = sect.querySelector('input[type=checkbox][data-k]').checked;
  }
  return out;
}
async function postJSON(url, body) { const r = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }); const d = await r.json().catch(() => ({})); if (r.status === 401) location.href = '/login'; if (!r.ok) throw new Error(d.error || 'Couldn’t save.'); return d; }
async function save() {
  const msg = $('#msg'); msg.className = 'muted'; msg.textContent = 'Saving…';
  try { const fields = await collect(); const d = await postJSON(`/api/config/${S.scope}`, { fields }); S.state = { ...S.state, everyone: d.everyone, kids: d.kids }; render(); $('#msg').className = 'ok'; $('#msg').textContent = '✓ Saved. iPads pick this up within 15 minutes.'; }
  catch (e) { msg.className = 'warn'; msg.textContent = e.message; }
}
async function loadHistory() {
  const list = await api(`/api/config/${S.scope}/history`), el = $('#hist');
  el.innerHTML = list.length ? list.map(h => { const d = h.version.replace(/(\d{4})(\d\d)(\d\d)T(\d\d)(\d\d)(\d\d)Z/, '$1-$2-$3T$4:$5:$6Z');
    return `<li>${when(d)}: ${esc(Object.keys(h.fields).join(', ') || 'nothing set')} <button data-restore="${h.version}">Restore</button></li>`; }).join('') : '<li class="muted">No earlier versions yet.</li>';
  el.querySelectorAll('[data-restore]').forEach(b => b.onclick = async () => { if (!confirm('Restore this version? The current settings are kept as an earlier version too.')) return;
    try { const d = await postJSON(`/api/config/${S.scope}/restore`, { version: b.dataset.restore }); S.state = { ...S.state, everyone: d.everyone, kids: d.kids }; render(); $('#msg').className = 'ok'; $('#msg').textContent = '✓ Restored.'; } catch (e) { alert(e.message); } });
}
async function openSettings() { S.state = await api('/api/config'); render(); }
$('#nav-activity').onclick = () => { $('#activity').hidden = false; $('#settings').hidden = true; $('#nav-activity').classList.add('on'); $('#nav-settings').classList.remove('on'); };
$('#nav-settings').onclick = async () => { $('#activity').hidden = true; $('#settings').hidden = false; $('#nav-settings').classList.add('on'); $('#nav-activity').classList.remove('on'); await openSettings(); };
