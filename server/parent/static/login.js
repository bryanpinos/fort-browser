const err = document.getElementById('err');
document.getElementById('go').onclick = async () => { err.textContent = ''; try { await signIn(); location.href = '/'; } catch (e) { err.textContent = e.name === 'NotAllowedError' ? 'Sign-in was cancelled.' : e.message; } };
if (window.top !== window.self) err.textContent = 'Passkeys can’t be used inside Home Assistant. Open parent.example.com in its own tab to sign in once.';
