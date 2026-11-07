// Wraps the image's /opt/browser-node/server.mjs so the screen only ever shows one page: no tab
// strip, no address bar, no window frame, no second window.
//
// Chromium's --kiosk does not reach the windows Playwright opens (its contexts start with
// --no-startup-window and every window is made over CDP), so the flags below are kept for the
// dialogs and bubbles they suppress, and the lock itself is a warden: one more client of this
// server, holding a browser-level CDP session, that puts every page target's window into
// browser fullscreen (Browser.setWindowBounds windowState "fullscreen", the same mode as F11)
// as soon as it appears, and checks again every KIOSK_WARDEN_INTERVAL_MS in case a key press
// left it. It opens no page and drives nothing. Its failures are logged and never stop the server.
//
// Mounted read-only beside server.mjs (so "playwright" and ./server.mjs resolve) and run in its
// place by browser-node-entrypoint.sh. No --disable-features here: Chromium keeps only the last
// one, and server.mjs passes its own list (storage partitioning stays on).
import { chromium } from "playwright";

export const KIOSK_ARGS = [
  "--kiosk",
  "--window-position=0,0",
  "--noerrdialogs",
  "--disable-session-crashed-bubble",
  "--hide-crash-restore-bubble",
  "--disable-pinch",
  "--overscroll-history-navigation=0",
  "--deny-permission-prompts",
];

const WARDEN_INTERVAL_MS = Number(process.env.KIOSK_WARDEN_INTERVAL_MS || 2000);
const short = (err) => String(err?.message || err).split("\n")[0];

export async function startWarden(server, { log = console, intervalMs = WARDEN_INTERVAL_MS } = {}) {
  const browser = await chromium.connect(server.wsEndpoint(), { timeout: 30000 });
  const cdp = await browser.newBrowserCDPSession();
  const lock = async (targetId) => {
    try {
      const { windowId, bounds } = await cdp.send("Browser.getWindowForTarget", { targetId });
      if (bounds.windowState !== "fullscreen") {
        await cdp.send("Browser.setWindowBounds", { windowId, bounds: { windowState: "fullscreen" } });
      }
    } catch (err) {
      // A target that closed in between has no window; anything else is worth a line.
      if (!/No target|not found|No web contents|closed/i.test(short(err))) log.warn(`kiosk warden: ${short(err)}`);
    }
  };
  cdp.on("Target.targetCreated", ({ targetInfo }) => { if (targetInfo.type === "page") lock(targetInfo.targetId); });
  await cdp.send("Target.setDiscoverTargets", { discover: true });
  const sweep = async () => {
    try {
      const { targetInfos } = await cdp.send("Target.getTargets");
      await Promise.all(targetInfos.filter((t) => t.type === "page").map((t) => lock(t.targetId)));
    } catch (err) { log.warn(`kiosk warden sweep: ${short(err)}`); }
  };
  await sweep();
  const timer = setInterval(sweep, intervalMs);
  timer.unref();
  browser.on("disconnected", () => clearInterval(timer));
  log.log("kiosk warden: every page window is held fullscreen");
  return { browser, stop: () => { clearInterval(timer); return browser.close().catch(() => {}); } };
}

const launch = chromium.launchServer.bind(chromium);
chromium.launchServer = async (options = {}) => {
  const server = await launch({ ...options, args: [...(options.args || []), ...KIOSK_ARGS] });
  startWarden(server).catch((err) => console.error(`kiosk warden did not start: ${short(err)}`));
  return server;
};

await import("./server.mjs");
