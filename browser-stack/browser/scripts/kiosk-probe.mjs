// Runs inside a browser-node container (piped to `node --input-type=module -` with the working
// directory /opt/browser-node, so `playwright` resolves to the image's copy). It connects to that
// container's own Playwright server, opens a page and a window.open popup, and prints one JSON
// line with each window's geometry. It never prints the endpoint, which carries a secret path.
//
// The window flags are browser-wide, so a fresh context on this connection shows what an agent's
// session shows. viewport: null keeps the window's own size. `kiosk` is the container's own
// BROWSER_KIOSK (docker exec inherits it): with 1 every window is fullscreen with no browser UI,
// with 0 maximized with its tab strip and address bar. windowShaped() below is the check, and is
// exported for bridge-smoke.mjs and pod-smoke.mjs (the probe's import of playwright resolves only
// in the container, so they copy it).
import { readFileSync } from "node:fs";
import { chromium } from "playwright";

const file = process.env.BROWSER_WS_ENDPOINT_FILE || "/data/profile/browser-ws-endpoint.txt";
const browser = await chromium.connect(readFileSync(file, "utf8").trim(), { timeout: 15000 });
const geometry = () => ({
  innerWidth, innerHeight, outerWidth, outerHeight, screenX, screenY,
  screenWidth: screen.width, screenHeight: screen.height,
});
const out = { kiosk: process.env.BROWSER_KIOSK === "1" };
try {
  const context = await browser.newContext({ viewport: null });
  const page = await context.newPage();
  await page.goto("data:text/html,<title>kiosk-probe</title><p>probe</p>");
  await page.waitForTimeout(500);
  out.page = await page.evaluate(geometry);
  const [popup] = await Promise.all([
    context.waitForEvent("page", { timeout: 10000 }),
    page.evaluate(() => { window.open("about:blank", "probe", "popup,width=300,height=200,left=50,top=50"); }),
  ]);
  await popup.waitForLoadState().catch(() => {});
  await popup.waitForTimeout(1000);
  out.popup = await popup.evaluate(geometry);
  out.pages = context.pages().length;
  await context.close();
} catch (err) {
  out.error = String(err?.message || err).split("\n")[0];
} finally {
  await browser.close().catch(() => {});
}
console.log(JSON.stringify(out));
