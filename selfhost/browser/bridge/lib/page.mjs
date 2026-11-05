// The phone page for /live/<id>. Self-contained: inline CSS and JS under a
// per-response CSP nonce, nothing loaded from elsewhere.

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const jsonForScript = (v) => JSON.stringify(v).replace(/</g, '\\u003c').replace(/\u2028/g, '\\u2028').replace(/\u2029/g, '\\u2029');

// Phone widths run 320–430 CSS px: nothing here has a fixed width, every box is
// border-box and at most 100% wide, and grid/flex children may shrink (min-width: 0)
// so a long title or URL wraps or ellipsizes instead of widening the page.
const style = ({ frameWidth, frameHeight }) => `
:root {
  color-scheme: light dark;
  --bg: #f6f6f4; --surface: #ffffff; --text: #1b1c1e; --muted: #6b6f76; --line: #e2e2de;
  --accent: #1f6feb; --accent-text: #ffffff;
  --watch-bg: #e7f0ff; --watch-fg: #1d4fa8;
  --need-bg: #fff1d6; --need-fg: #8a5300;
  --done-bg: #e3f4e8; --done-fg: #1d6b38;
  --err-bg: #fde7e7; --err-fg: #9b1c1c;
  --frame-ar: ${frameWidth} / ${frameHeight};
  --gutter-l: max(16px, env(safe-area-inset-left));
  --gutter-r: max(16px, env(safe-area-inset-right));
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #111214; --surface: #1b1d20; --text: #eceef1; --muted: #9aa0a8; --line: #2c2f34;
    --accent: #4c8dff; --accent-text: #0b0c0e;
    --watch-bg: #172640; --watch-fg: #9cc1ff;
    --need-bg: #3a2a0c; --need-fg: #ffcf73;
    --done-bg: #12301d; --done-fg: #8fe0a8;
    --err-bg: #3a1414; --err-fg: #ffb4b4;
  }
}
*, *::before, *::after { box-sizing: border-box; }
[hidden] { display: none !important; }
html, body { margin: 0; width: 100%; max-width: 100%; overflow-x: clip; background: var(--bg); color: var(--text);
  font: 15px/1.4 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
body { min-height: 100vh; min-height: 100dvh; display: flex; flex-direction: column; }
header { position: sticky; top: 0; z-index: 1; width: 100%; background: var(--surface); border-bottom: 1px solid var(--line);
  padding: max(10px, env(safe-area-inset-top)) var(--gutter-r) 10px var(--gutter-l);
  display: grid; gap: 2px 10px; grid-template-columns: minmax(0, 1fr) auto; align-items: center; }
#title { min-width: 0; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
#url { grid-column: 1 / -1; min-width: 0; color: var(--muted); font-size: 12.5px;
  overflow-wrap: anywhere; word-break: break-all;
  display: -webkit-box; -webkit-box-orient: vertical; -webkit-line-clamp: 2; overflow: hidden; }
.pill { font-size: 12px; font-weight: 600; padding: 3px 10px; border-radius: 999px; white-space: nowrap; }
.pill.watching { background: var(--watch-bg); color: var(--watch-fg); }
.pill.takeover { background: var(--need-bg); color: var(--need-fg); }
.pill.user { background: var(--accent); color: var(--accent-text); }
.pill.done, .pill.ended { background: var(--done-bg); color: var(--done-fg); }
#reason { margin: 12px var(--gutter-r) 0 var(--gutter-l); padding: 10px 12px; border-radius: 10px;
  background: var(--need-bg); color: var(--need-fg); overflow-wrap: anywhere; }
main { flex: 1; width: 100%; min-width: 0; padding: 12px var(--gutter-r) 12px var(--gutter-l); }
#box { position: relative; width: 100%; max-width: ${frameWidth}px; margin: 0 auto; aspect-ratio: var(--frame-ar);
  max-height: calc(100vh - 170px); max-height: calc(100dvh - 170px); min-height: 200px;
  border-radius: 10px; border: 1px solid var(--line); background: var(--surface); overflow: hidden; }
#frame { position: absolute; inset: 0; display: block; width: 100%; height: 100%; max-width: 100%;
  object-fit: contain; object-position: center top; }
#note { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center;
  padding: 16px; text-align: center; color: var(--muted); overflow-wrap: anywhere; }
#note.over { inset: auto 0 0 0; background: var(--surface); border-top: 1px solid var(--line); }
#note.error { color: var(--err-fg); background: var(--err-bg); }
footer { position: sticky; bottom: 0; width: 100%; background: var(--surface); border-top: 1px solid var(--line);
  padding: 10px var(--gutter-r) max(10px, env(safe-area-inset-bottom)) var(--gutter-l); display: flex; gap: 10px; }
.btn { flex: 1 1 0; min-width: 0; display: inline-flex; justify-content: center; align-items: center; min-height: 44px;
  padding: 0 12px; border-radius: 10px; font: inherit; font-weight: 600; text-decoration: none; cursor: pointer;
  border: 1px solid var(--line); background: var(--surface); color: var(--text); text-align: center; }
.btn.primary { background: var(--accent); color: var(--accent-text); border-color: var(--accent); }
.btn:disabled { opacity: .5; }
`;

// Frame failures in a row before the page says so instead of spinning quietly.
export const FRAME_FAILURES_BEFORE_ERROR = 4;

const SCRIPT = `
(() => {
  const base = location.pathname.replace(/\\/+$/, '');
  const LABEL = { watching: 'Watching', takeover: 'Needs you', user: 'You have control', done: 'Done', ended: 'Ended' };
  const MAX_FAILS = ${FRAME_FAILURES_BEFORE_ERROR};
  const $ = (id) => document.getElementById(id);
  let state = JSON.parse($('initial').textContent);
  let stopped = false, timer = null, lastObjectUrl = null, fails = 0, haveFrame = false;

  const ended = () => state.status === 'done' && state.reason === 'session_closed';

  function note(text, { error = false } = {}) {
    const n = $('note');
    n.textContent = text;
    n.hidden = false;
    n.classList.toggle('error', error);
    n.classList.toggle('over', haveFrame && !$('frame').hidden);
  }

  function render() {
    const status = ended() ? 'ended' : state.status;
    $('pill').textContent = LABEL[status] || status;
    $('pill').className = 'pill ' + status;
    $('title').textContent = state.title || 'Browser';
    $('url').textContent = state.url || '';
    const needs = state.status === 'takeover';
    $('reason').hidden = !needs;
    $('reason').textContent = needs ? (state.reason || 'The agent needs you to take over.') : '';
    const held = needs || state.status === 'user';
    $('done').hidden = !held;
    $('take').classList.toggle('primary', needs);
    document.title = (needs ? '⚠ ' : '') + (state.title || 'Live browser');
  }

  function stop() { stopped = true; clearTimeout(timer); $('take').hidden = true; $('done').hidden = true; }

  function finish() {
    if (!ended()) state = Object.assign({}, state, { status: 'done', reason: 'session_closed' });
    render();
    stop();
    $('frame').hidden = true;
    haveFrame = false;
    note('This live browser has ended.');
  }

  function gone(code) {
    stop();
    $('frame').hidden = true;
    haveFrame = false;
    note(code === 410 ? 'This live view has expired.' : 'This live view is no longer available.');
  }

  function failed(code) {
    fails++;
    if (fails >= MAX_FAILS) {
      note("The live view isn't loading" + (code ? ' (error ' + code + ')' : ' (no connection)') + '. Still trying…', { error: true });
    }
  }

  async function tick() {
    if (stopped) return;
    try {
      const s = await fetch(base + '/state', { cache: 'no-store' });
      if (s.status === 404 || s.status === 410) return gone(s.status);
      if (s.ok) { state = await s.json(); render(); }
      if (ended()) return finish();
      // A sleeping browser has no frames; it wakes when the agent uses it or on Take control.
      if (state.pod === 'asleep' || state.pod === 'crashed') {
        note(state.pod === 'asleep' ? 'The browser is asleep. Take control to wake it.' : 'The browser stopped. It restarts when it is used.');
        return schedule();
      }
      const f = await fetch(base + '/frame.jpg', { cache: 'no-store' });
      if (f.status === 410) return gone(410);
      if (f.status === 404) return finish();
      if (f.ok) {
        const url = URL.createObjectURL(await f.blob());
        const img = $('frame');
        img.onload = () => {
          if (lastObjectUrl && lastObjectUrl !== url) URL.revokeObjectURL(lastObjectUrl);
          lastObjectUrl = url;
          if (img.naturalWidth && img.naturalHeight) {
            $('box').style.setProperty('--frame-ar', img.naturalWidth + ' / ' + img.naturalHeight);
          }
        };
        img.src = url;
        img.hidden = false;
        haveFrame = true;
        fails = 0;
        $('note').hidden = true;
      } else {
        failed(f.status);
      }
    } catch (e) {
      failed(0); // offline for a moment: keep the last frame
    }
    schedule();
  }
  function schedule() { clearTimeout(timer); if (!stopped && !document.hidden) timer = setTimeout(tick, 1500); }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); else clearTimeout(timer); });

  // noVNC is served by the bridge under this link (<base>/vnc/). Open it at this page's own
  // origin and path prefix, so it works however the page was reached, and point noVNC's
  // websocket (path=, relative to the origin) at the same prefix. The fragment (the password)
  // is kept as it is. Any other URL is opened unchanged.
  function viaPage(u) {
    try {
      const v = new URL(u, location.href);
      if (!/\\/live\\/[0-9a-f]{32}\\/vnc\\/vnc\\.html$/.test(v.pathname)) return u;
      const q = new URLSearchParams(v.search);
      q.delete('path');
      const rest = q.toString();
      return location.origin + base + '/vnc/vnc.html?' + (rest ? rest + '&' : '') +
        'path=' + base.replace(/^\\/+/, '') + '/vnc/websockify' + v.hash;
    } catch (err) { return u; }
  }

  // Take control records that the user has the browser (the agent's actions are refused until
  // Release control), then opens noVNC. Without script the link still opens noVNC.
  $('take').addEventListener('click', async (e) => {
    e.preventDefault();
    const fallback = $('take').href;
    try {
      let r = await fetch(base + '/take', { method: 'POST' });
      // 202: the browser was asleep and is starting; ask again until it runs (about 4 s).
      for (let i = 0; r.status === 202 && i < 30; i++) {
        note('Starting the browser…');
        await new Promise((ok) => setTimeout(ok, 1000));
        r = await fetch(base + '/take', { method: 'POST' });
      }
      if (r.ok && r.status !== 202) {
        const t = await r.json();
        state = t; render();
        location.href = viaPage(t.novnc_url || fallback);
        return;
      }
      if (r.status === 409) return finish();
    } catch (err) {}
    location.href = viaPage(fallback);
  });

  $('done').addEventListener('click', async () => {
    $('done').disabled = true;
    try {
      const r = await fetch(base + '/release', { method: 'POST' });
      if (r.ok) { state = await r.json(); render(); }
    } finally { $('done').disabled = false; }
  });

  render();
  if (ended()) finish(); else tick();
})();
`;

export function renderPage({ id, state, takeoverUrl, nonce, frameWidth = 1920, frameHeight = 1200 }) {
    const fw = Math.max(1, Math.round(Number(frameWidth) || 1920));
    const fh = Math.max(1, Math.round(Number(frameHeight) || 1200));
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<title>${esc(state.title || 'Live browser')}</title>
<style nonce="${nonce}">${style({ frameWidth: fw, frameHeight: fh })}</style>
</head>
<body>
<header>
  <div id="title">${esc(state.title || 'Browser')}</div>
  <span id="pill" class="pill ${esc(state.status)}"></span>
  <div id="url">${esc(state.url || '')}</div>
</header>
<div id="reason" hidden></div>
<main>
  <div id="box">
    <img id="frame" alt="Live view of the agent's browser" hidden>
    <div id="note" role="status">Loading the live view…</div>
  </div>
</main>
<footer>
  <a id="take" class="btn" href="${esc(takeoverUrl)}" rel="noreferrer">Take control</a>
  <button id="done" class="btn primary" type="button" hidden>Release control</button>
</footer>
<script id="initial" type="application/json">${jsonForScript(state)}</script>
<script nonce="${nonce}">${SCRIPT}</script>
</body>
</html>`;
}

export function renderGone(message) {
    return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark"><title>Live browser</title></head>
<body style="margin:0;font:16px -apple-system,system-ui,sans-serif;padding:40px 16px;text-align:center;overflow-wrap:anywhere">${esc(message)}</body></html>`;
}
