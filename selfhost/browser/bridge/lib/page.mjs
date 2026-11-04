// The phone page for /live/<id>. Self-contained: inline CSS and JS under a
// per-response CSP nonce, nothing loaded from elsewhere.

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const jsonForScript = (v) => JSON.stringify(v).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');

const STYLE = `
:root {
  color-scheme: light dark;
  --bg: #f6f6f4; --surface: #ffffff; --text: #1b1c1e; --muted: #6b6f76; --line: #e2e2de;
  --accent: #1f6feb; --accent-text: #ffffff;
  --watch-bg: #e7f0ff; --watch-fg: #1d4fa8;
  --need-bg: #fff1d6; --need-fg: #8a5300;
  --done-bg: #e3f4e8; --done-fg: #1d6b38;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111214; --surface: #1b1d20; --text: #eceef1; --muted: #9aa0a8; --line: #2c2f34;
    --accent: #4c8dff; --accent-text: #0b0c0e;
    --watch-bg: #172640; --watch-fg: #9cc1ff;
    --need-bg: #3a2a0c; --need-fg: #ffcf73;
    --done-bg: #12301d; --done-fg: #8fe0a8;
  }
}
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text);
  font: 15px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
body { min-height: 100vh; display: flex; flex-direction: column; }
header { position: sticky; top: 0; z-index: 1; background: var(--surface); border-bottom: 1px solid var(--line);
  padding: 10px 16px; padding-top: max(10px, env(safe-area-inset-top)); display: grid; gap: 2px;
  grid-template-columns: 1fr auto; align-items: center; }
#title { font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
#url { grid-column: 1 / -1; color: var(--muted); font-size: 12.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pill { font-size: 12px; font-weight: 600; padding: 3px 10px; border-radius: 999px; white-space: nowrap; }
.pill.watching { background: var(--watch-bg); color: var(--watch-fg); }
.pill.takeover { background: var(--need-bg); color: var(--need-fg); }
.pill.done { background: var(--done-bg); color: var(--done-fg); }
#reason { margin: 12px 16px 0; padding: 10px 12px; border-radius: 10px; background: var(--need-bg); color: var(--need-fg); }
#reason[hidden], #done[hidden] { display: none; }
main { flex: 1; padding: 12px 16px; display: flex; justify-content: center; align-items: flex-start; }
#frame { display: block; max-width: 100%; height: auto; border-radius: 10px; border: 1px solid var(--line);
  background: var(--surface); min-height: 200px; }
#note { color: var(--muted); text-align: center; padding: 40px 16px; }
footer { position: sticky; bottom: 0; background: var(--surface); border-top: 1px solid var(--line);
  padding: 10px 16px; padding-bottom: max(10px, env(safe-area-inset-bottom)); display: flex; gap: 10px; }
.btn { flex: 1; display: inline-flex; justify-content: center; align-items: center; min-height: 44px;
  border-radius: 10px; font: inherit; font-weight: 600; text-decoration: none; cursor: pointer;
  border: 1px solid var(--line); background: var(--surface); color: var(--text); }
.btn.primary { background: var(--accent); color: var(--accent-text); border-color: var(--accent); }
.btn:disabled { opacity: .5; }
`;

const SCRIPT = `
(() => {
  const base = location.pathname.replace(/\\/+$/, '');
  const LABEL = { watching: 'Watching', takeover: 'Needs you', done: 'Done' };
  const $ = (id) => document.getElementById(id);
  let state = JSON.parse($('initial').textContent);
  let stopped = false, timer = null, lastObjectUrl = null;

  function render() {
    $('pill').textContent = LABEL[state.status] || state.status;
    $('pill').className = 'pill ' + state.status;
    $('title').textContent = state.title || 'Browser';
    $('url').textContent = state.url || '';
    const needs = state.status === 'takeover';
    $('reason').hidden = !needs;
    $('reason').textContent = needs ? (state.reason || 'The agent needs you to take over.') : '';
    $('done').hidden = !needs;
    $('take').classList.toggle('primary', needs);
    document.title = (needs ? '⚠ ' : '') + (state.title || 'Live browser');
  }

  function gone(code) {
    stopped = true;
    clearTimeout(timer);
    $('note').textContent = code === 410 ? 'This live view has expired.' : 'This live view is no longer available.';
    $('note').hidden = false;
    $('frame').hidden = true;
    $('take').hidden = true;
    $('done').hidden = true;
  }

  async function tick() {
    if (stopped) return;
    try {
      const s = await fetch(base + '/state', { cache: 'no-store' });
      if (s.status === 404 || s.status === 410) return gone(s.status);
      if (s.ok) { state = await s.json(); render(); }
      if (state.status === 'done' && state.reason === 'session_closed') {
        $('note').textContent = 'The browser session has closed.'; $('note').hidden = false;
      } else {
        const f = await fetch(base + '/frame.jpg', { cache: 'no-store' });
        if (f.status === 410) return gone(410);
        if (f.ok) {
          const url = URL.createObjectURL(await f.blob());
          const img = $('frame');
          img.onload = () => { if (lastObjectUrl && lastObjectUrl !== url) URL.revokeObjectURL(lastObjectUrl); lastObjectUrl = url; };
          img.src = url;
          img.hidden = false;
          $('note').hidden = true;
        }
      }
    } catch (e) { /* offline for a moment: keep the last frame */ }
    schedule();
  }
  function schedule() { clearTimeout(timer); if (!stopped && !document.hidden) timer = setTimeout(tick, 1500); }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); else clearTimeout(timer); });

  $('done').addEventListener('click', async () => {
    $('done').disabled = true;
    try {
      const r = await fetch(base + '/done', { method: 'POST' });
      if (r.ok) { state = await r.json(); render(); }
    } finally { $('done').disabled = false; }
  });

  render();
  tick();
})();
`;

export function renderPage({ id, state, takeoverUrl, nonce }) {
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<title>${esc(state.title || 'Live browser')}</title>
<style nonce="${nonce}">${STYLE}</style>
</head>
<body>
<header>
  <div id="title">${esc(state.title || 'Browser')}</div>
  <span id="pill" class="pill ${esc(state.status)}"></span>
  <div id="url">${esc(state.url || '')}</div>
</header>
<div id="reason" hidden></div>
<main>
  <img id="frame" alt="Live view of the agent's browser" hidden>
  <div id="note">Loading the live view…</div>
</main>
<footer>
  <a id="take" class="btn" href="${esc(takeoverUrl)}" rel="noreferrer">Take control</a>
  <button id="done" class="btn primary" type="button" hidden>Done</button>
</footer>
<script id="initial" type="application/json">${jsonForScript(state)}</script>
<script nonce="${nonce}">${SCRIPT}</script>
</body>
</html>`;
}

export function renderGone(message) {
    return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark"><title>Live browser</title></head>
<body style="font:16px -apple-system,system-ui,sans-serif;padding:40px 16px;text-align:center">${esc(message)}</body></html>`;
}
