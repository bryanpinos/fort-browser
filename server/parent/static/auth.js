// Passkey helpers: WebAuthn JSON <-> browser objects.
const b64u = {
  toBuf: s => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(s.length / 4) * 4, '=')), c => c.charCodeAt(0)).buffer,
  fromBuf: b => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
};
function credToJSON(c) {
  const r = c.response, out = { id: c.id, rawId: b64u.fromBuf(c.rawId), type: c.type, clientExtensionResults: c.getClientExtensionResults(), response: {} };
  for (const k of ['clientDataJSON', 'attestationObject', 'authenticatorData', 'signature', 'userHandle']) if (r[k]) out.response[k] = b64u.fromBuf(r[k]);
  if (r.getTransports) out.response.transports = r.getTransports();
  return out;
}
async function post(url, body) {
  const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || 'Something went wrong.');
  return data;
}
async function signIn() {
  const { challenge_id, options } = await post('/auth/login/options', {});
  options.challenge = b64u.toBuf(options.challenge);
  (options.allowCredentials || []).forEach(c => c.id = b64u.toBuf(c.id));
  const cred = await navigator.credentials.get({ publicKey: options });
  await post('/auth/login/verify', { challenge_id, credential: credToJSON(cred) });
}
async function register(code, name) {
  const { challenge_id, options } = await post('/auth/register/options', { code });
  options.challenge = b64u.toBuf(options.challenge);
  options.user.id = b64u.toBuf(options.user.id);
  (options.excludeCredentials || []).forEach(c => c.id = b64u.toBuf(c.id));
  const cred = await navigator.credentials.create({ publicKey: options });
  await post('/auth/register/verify', { code, challenge_id, name, credential: credToJSON(cred) });
}
