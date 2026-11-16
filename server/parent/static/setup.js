const code = location.hash.slice(1), err = document.getElementById('err');
if (!code) err.textContent = 'This link is missing its setup code.';
document.getElementById('go').onclick = async () => { err.textContent = ''; try { await register(code, document.getElementById('name').value || 'passkey'); history.replaceState(null, '', '/setup'); location.href = '/'; } catch (e) { err.textContent = e.name === 'NotAllowedError' ? 'Cancelled.' : e.message; } };
