// Wraps the image's /opt/browser-node/server.mjs and holds every Chromium page window in one shape,
// so the screen only ever shows the browser:
//
//   BROWSER_KIOSK=0 (the default): a normal Chromium window, maximized to the whole screen, with its
//     tab strip and address bar. Never fullscreen, never minimized, never a smaller window.
//   BROWSER_KIOSK=1: kiosk. One page and nothing else: no tab strip, no address bar, no window
//     frame (browser fullscreen, the same mode as F11).
//
// Chromium's --kiosk and --start-maximized do not reach the windows Playwright opens (its contexts
// start with --no-startup-window and every window is made over CDP, sized to the viewport), so the
// flags below are kept for the dialogs and bubbles they suppress, and the shape itself is kept by a
// warden: one more client of this server, holding a browser-level CDP session, that sets every page
// target's window to the mode above (Browser.setWindowBounds windowState) as soon as it appears,
// and checks again every KIOSK_WARDEN_INTERVAL_MS in case a key press, a double click on the tab
// strip or the minimize button changed it. It opens no page and drives nothing. Its failures are
// logged and never stop the server.
//
// The warden also sends any page that commits a view-source: URL to about:blank. policy.json's
// URLBlocklist is checked against the inner URL only (and "view-source:*" in it has no effect), so
// without this `view-source:file:///etc/passwd`, typed into the address bar, shows the file in
// spite of the file:// block. DeveloperToolsAvailability=2 would block view-source in Chromium
// itself, but it breaks Playwright (newPage fails). The page is pushed off as soon as Chromium
// reports the commit, over a non-flattened attach (Playwright's CDP session cannot address a
// child session), so at most a moment of it is ever on screen.
//
// Mounted read-only beside server.mjs (so "playwright" and ./server.mjs resolve) and run in its
// place by browser-node-entrypoint.sh. No --disable-features here: Chromium keeps only the last
// one, and server.mjs passes its own list (storage partitioning stays on).
import { chromium } from "playwright";

const COMMON_ARGS = [
  "--window-position=0,0",
  "--noerrdialogs",
  "--disable-session-crashed-bubble",
  "--hide-crash-restore-bubble",
  "--disable-pinch",
  "--overscroll-history-navigation=0",
  "--deny-permission-prompts",
];
export const KIOSK_ARGS = ["--kiosk", ...COMMON_ARGS];
export const WINDOW_ARGS = ["--start-maximized", ...COMMON_ARGS];

/** BROWSER_KIOSK: "1" kiosk, anything else (unset, "0") a maximized normal window. */
export const kioskMode = (env = process.env) => String(env.BROWSER_KIOSK ?? "") === "1";
export const argsFor = (kiosk) => (kiosk ? KIOSK_ARGS : WINDOW_ARGS);
export const wantedState = (kiosk) => (kiosk ? "fullscreen" : "maximized");

/**
 * The CDP calls that take a window from `current` to `wanted`. Chromium only goes to maximized
 * from normal: a fullscreen or minimized window is restored first.
 */
export function stepsTo(current, wanted) {
  if (current === wanted) return [];
  if (wanted === "maximized" && (current === "fullscreen" || current === "minimized")) return ["normal", "maximized"];
  return [wanted];
}

/** A URL the warden sends to about:blank as soon as a page commits it. */
export const forbiddenUrl = (url) => /^\s*view-source:/i.test(String(url || ""));

const WARDEN_INTERVAL_MS = Number(process.env.KIOSK_WARDEN_INTERVAL_MS || 2000);
const short = (err) => String(err?.message || err).split("\n")[0];

export async function startWarden(server, { log = console, intervalMs = WARDEN_INTERVAL_MS, kiosk = kioskMode() } = {}) {
  const browser = await chromium.connect(server.wsEndpoint(), { timeout: 30000 });
  const cdp = await browser.newBrowserCDPSession();
  return watch(cdp, { log, intervalMs, kiosk, onStop: () => browser.close().catch(() => {}), browser });
}

/** The warden over any CDP session (`send`, `on`): exported for the tests. */
export async function watch(cdp, { log = console, intervalMs = WARDEN_INTERVAL_MS, kiosk = false, onStop = () => {}, browser = null } = {}) {
  const wanted = wantedState(kiosk);
  const busy = new Set();
  const hold = async (targetId) => {
    if (busy.has(targetId)) return;
    busy.add(targetId);
    try {
      const { windowId, bounds } = await cdp.send("Browser.getWindowForTarget", { targetId });
      for (const windowState of stepsTo(bounds.windowState, wanted)) {
        await cdp.send("Browser.setWindowBounds", { windowId, bounds: { windowState } });
      }
    } catch (err) {
      // A target that closed in between has no window; anything else is worth a line.
      if (!/No target|not found|No web contents|closed/i.test(short(err))) log.warn(`kiosk warden: ${short(err)}`);
    } finally {
      busy.delete(targetId);
    }
  };
  const evicting = new Set();
  const evict = async (targetId, url) => {
    if (evicting.has(targetId)) return;
    evicting.add(targetId);
    try {
      const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: false });
      try {
        await cdp.send("Target.sendMessageToTarget", { sessionId, message: JSON.stringify({ id: 1, method: "Page.navigate", params: { url: "about:blank" } }) });
      } finally {
        await cdp.send("Target.detachFromTarget", { sessionId }).catch(() => {});
      }
      log.warn(`kiosk warden: sent a ${String(url).split(":")[0]}: page to about:blank`);
    } catch (err) {
      if (!/No target|not found|No web contents|closed/i.test(short(err))) log.warn(`kiosk warden: ${short(err)}`);
    } finally {
      evicting.delete(targetId);
    }
  };
  const check = (t) => { if (t.type === "page" && forbiddenUrl(t.url)) evict(t.targetId, t.url); };
  cdp.on("Target.targetCreated", ({ targetInfo }) => { if (targetInfo.type === "page") { hold(targetInfo.targetId); check(targetInfo); } });
  cdp.on("Target.targetInfoChanged", ({ targetInfo }) => check(targetInfo));
  await cdp.send("Target.setDiscoverTargets", { discover: true });
  const sweep = async () => {
    try {
      const { targetInfos } = await cdp.send("Target.getTargets");
      const pages = targetInfos.filter((t) => t.type === "page");
      pages.forEach(check);
      await Promise.all(pages.map((t) => hold(t.targetId)));
    } catch (err) { log.warn(`kiosk warden sweep: ${short(err)}`); }
  };
  await sweep();
  const timer = setInterval(sweep, intervalMs);
  timer.unref?.();
  browser?.on?.("disconnected", () => clearInterval(timer));
  log.log(kiosk ? "kiosk warden: every page window is held fullscreen (BROWSER_KIOSK=1)"
    : "kiosk warden: every page window is held maximized, with its tab strip and address bar");
  return { browser, sweep, stop: () => { clearInterval(timer); return onStop(); } };
}

// Imported by the tests: only the functions above, no launch.
if (process.env.HAPPY_KIOSK_NO_AUTOLOAD !== "1") {
  const kiosk = kioskMode();
  const launch = chromium.launchServer.bind(chromium);
  chromium.launchServer = async (options = {}) => {
    const server = await launch({ ...options, args: [...(options.args || []), ...argsFor(kiosk)] });
    startWarden(server, { kiosk }).catch((err) => console.error(`kiosk warden did not start: ${short(err)}`));
    return server;
  };
  await import("./server.mjs");
}
