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
#approval { margin: 12px var(--gutter-r) 0 var(--gutter-l); padding: 12px; border-radius: 10px;
  background: var(--need-bg); color: var(--need-fg); border: 1px solid var(--need-fg); overflow-wrap: anywhere; }
#approval h2 { margin: 0 0 4px; font-size: 16px; }
#approval p { margin: 0 0 6px; }
#approval ul { margin: 0 0 10px; padding-left: 18px; }
#approval .row { display: flex; gap: 10px; }
#approval .btn.deny { color: var(--err-fg); }
#approval-msg { margin-top: 8px; font-size: 13px; }
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
/* Waiting for a frame (the first, or one the browser is slow to give while the agent acts):
   a spinner over the middle of the picture, the last frame kept under it; above the words
   when there are some. */
#spin { position: absolute; top: 50%; left: 50%; width: 40px; height: 40px; margin: -20px 0 0 -20px;
  border-radius: 50%; background: rgba(0, 0, 0, .45); pointer-events: none; }
#box.noting #spin { margin-top: -64px; }
#spin::after { content: ''; position: absolute; inset: 9px; border-radius: 50%;
  border: 3px solid rgba(255, 255, 255, .3); border-top-color: #fff; animation: spin .8s linear infinite; }
@keyframes spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { #spin::after { animation-duration: 2.4s; } }
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
// A frame asked for and not answered for this long: the spinner shows over the last one.
export const FRAME_WAIT_SPIN_MS = 1200;
// From one frame's answer to the next ask. The bridge makes about one fresh frame a second
// (each is scrubbed), so frames are asked back to back rather than on a slow clock.
export const FRAME_GAP_MS = 300;

const SCRIPT = `
(() => {
  const base = location.pathname.replace(/\\/+$/, '');
  const LABEL = { watching: 'Watching', takeover: 'Needs you', user: 'You have control', done: 'Done', ended: 'Ended' };
  const MAX_FAILS = ${FRAME_FAILURES_BEFORE_ERROR};
  const SPIN_MS = ${FRAME_WAIT_SPIN_MS};
  const GAP_MS = ${FRAME_GAP_MS};
  const $ = (id) => document.getElementById(id);
  let state = JSON.parse($('initial').textContent);
  let stopped = false, timer = null, lastObjectUrl = null, fails = 0, haveFrame = false, spinTimer = null;

  function spin(on) {
    clearTimeout(spinTimer);
    spinTimer = null;
    $('spin').hidden = !on;
    $('box').classList.toggle('noting', !$('note').hidden && !$('note').classList.contains('over'));
  }

  const ended = () => state.status === 'done' && state.reason === 'session_closed';

  function note(text, { error = false } = {}) {
    const n = $('note');
    n.textContent = text;
    n.hidden = false;
    n.classList.toggle('error', error);
    n.classList.toggle('over', haveFrame && !$('frame').hidden);
    $('box').classList.toggle('noting', !n.classList.contains('over'));
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
    // Sleep: only for a chat's own browser (state.pod) while it runs; it wakes on the next use.
    $('sleep').hidden = stopped || state.status === 'done' || !(state.pod === 'running' || state.pod === 'starting');
    $('take').classList.toggle('primary', needs);
    renderApproval();
    document.title = (needs || state.approval ? '⚠ ' : '') + (state.title || 'Live browser');
  }

  // The action the agent is waiting on the user's yes for. Text only (textContent): the summary
  // comes scrubbed from the bridge, never with what was typed.
  let shownApproval = null, deciding = false;
  function renderApproval() {
    const a = state.status !== 'done' ? state.approval : null;
    $('approval').hidden = !a;
    if (!a) { shownApproval = null; return; }
    if (shownApproval === a.id) return;
    shownApproval = a.id;
    $('approval-summary').textContent = a.summary || 'The agent wants to do something that needs your approval.';
    const list = $('approval-details');
    list.textContent = '';
    for (const d of (Array.isArray(a.details) ? a.details : [])) {
      const li = document.createElement('li');
      li.textContent = String(d);
      list.appendChild(li);
    }
    $('approval-msg').textContent = '';
    $('approve').disabled = $('deny').disabled = false;
  }

  async function decide(approve) {
    const a = state.approval;
    if (!a || deciding) return;
    deciding = true;
    $('approve').disabled = $('deny').disabled = true;
    $('approval-msg').textContent = approve ? 'Approving…' : 'Denying…';
    try {
      const r = await fetch(base + (approve ? '/approve' : '/deny'), {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ approval_id: a.id }),
      });
      const body = await r.json().catch(() => null);
      if (body && body.status) { state = body; shownApproval = null; render(); }
      if (!r.ok) {
        $('approval-msg').textContent = r.status === 409 ? 'This request is no longer waiting.' : 'That did not go through. Try again.';
        $('approve').disabled = $('deny').disabled = !state.approval;
      }
    } catch (e) {
      $('approval-msg').textContent = 'No connection. Try again.';
      $('approve').disabled = $('deny').disabled = false;
    } finally { deciding = false; }
  }
  $('approve').addEventListener('click', () => decide(true));
  $('deny').addEventListener('click', () => decide(false));

  function stop() { stopped = true; clearTimeout(timer); spin(false); $('take').hidden = true; $('done').hidden = true; $('sleep').hidden = true; }

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
        spin(false);
        note(state.pod === 'asleep' ? 'The browser is asleep. Take control to wake it.' : 'The browser stopped. It restarts when it is used.');
        return schedule();
      }
      // No picture yet: spinning already. Else only once this frame is slow in coming.
      if (!haveFrame) spin(true);
      else if (!spinTimer && $('spin').hidden) spinTimer = setTimeout(() => spin(true), SPIN_MS);
      const f = await fetch(base + '/frame.jpg', { cache: 'no-store' });
      clearTimeout(spinTimer);
      spinTimer = null;
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
        spin(false);
        return schedule(GAP_MS);
      } else {
        failed(f.status);
      }
    } catch (e) {
      clearTimeout(spinTimer);
      spinTimer = null;
      failed(0); // offline for a moment: keep the last frame
    }
    schedule();
  }
  function schedule(ms = 1500) { clearTimeout(timer); if (!stopped && !document.hidden) timer = setTimeout(tick, ms); }
  document.addEventListener('visibilitychange', () => { if (!document.hidden) tick(); else clearTimeout(timer); });

  // noVNC is served by the bridge under this link (<base>/vnc/). Open it at this page's own
  // origin and path prefix, so it works however the page was reached, and point noVNC's
  // websocket (path=, which noVNC resolves against vnc.html's URL) at the same prefix. The fragment (the password)
  // is kept as it is. Any other URL is opened unchanged.
  function viaPage(u) {
    try {
      const v = new URL(u, location.href);
      if (!/\\/live\\/[0-9a-f]{32}\\/vnc\\/vnc\\.html$/.test(v.pathname)) return u;
      const q = new URLSearchParams(v.search);
      q.delete('path');
      const rest = q.toString();
      return location.origin + base + '/vnc/vnc.html?' + (rest ? rest + '&' : '') +
        'path=websockify' + v.hash;
    } catch (err) { return u; }
  }

  // Take control records that the user has the browser (the agent's actions are refused until
  // Release control), then opens noVNC with the password /take answers with. Without script the
  // link still opens noVNC, which then asks for the password.
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

  // Sleep stops the browser and keeps its login and page; the agent's next call or Take control
  // wakes it where it was.
  $('sleep').addEventListener('click', async () => {
    $('sleep').disabled = true;
    try {
      const r = await fetch(base + '/sleep', { method: 'POST' });
      const body = await r.json().catch(() => null);
      if (body && body.status) { state = body; render(); }
      if (r.ok && state.pod === 'asleep') {
        $('frame').hidden = true;
        haveFrame = false;
        spin(false);
        note('The browser is asleep. Take control to wake it.');
      }
    } catch (err) {
    } finally { $('sleep').disabled = false; }
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
<section id="approval" role="alertdialog" aria-labelledby="approval-title" hidden>
  <h2 id="approval-title">Allow this browser action?</h2>
  <p id="approval-summary"></p>
  <ul id="approval-details"></ul>
  <div class="row">
    <button id="deny" class="btn deny" type="button">Deny</button>
    <button id="approve" class="btn primary" type="button">Approve</button>
  </div>
  <div id="approval-msg" role="status"></div>
</section>
<main>
  <div id="box" class="noting">
    <img id="frame" alt="Live view of the agent's browser" hidden>
    <div id="note" role="status">Loading the live view…</div>
    <div id="spin" aria-hidden="true"></div>
  </div>
</main>
<footer>
  <a id="take" class="btn" href="${esc(takeoverUrl)}" rel="noreferrer">Take control</a>
  <button id="done" class="btn primary" type="button" hidden>Release control</button>
  <button id="sleep" class="btn" type="button" hidden>Sleep</button>
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
