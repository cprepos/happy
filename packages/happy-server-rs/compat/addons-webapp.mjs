// Addons: the bundled web app (src/addons/webapp.rs) against main.ts
// staticWebappOptions and the static part of api.ts (@fastify/static, the
// server check hook, the injected config, the SPA fallback). The env file
// decides the directory (testdata/addons-webapp) and the injected config:
//   addons-webapp          with HAPPY_INJECT_HTML_CONFIG
//   addons-webapp-plain    without it
//   addons-webapp-noindex  a directory without index.html: no web app
// Validators (etag, last-modified) are compared by how the server answers
// them, not by value: the two servers stat the same files but format them
// independently.
import http from 'node:http';
import { login } from './phase2.mjs';

/**
 * A request through node:http, which, unlike fetch, sends conditional headers
 * as given (fetch adds `Cache-Control: no-cache` to them). Records the status,
 * the headers that matter and the body.
 */
function raw(t, name, path, headers = {}, method = 'GET') {
    const url = new URL(t.base + path);
    return new Promise((resolve) => {
        const req = http.request({ host: url.hostname, port: url.port, path, method, headers }, (res) => {
            const chunks = [];
            res.on('data', (c) => chunks.push(c));
            res.on('end', () => {
                const keep = ['content-type', 'content-range', 'content-length', 'accept-ranges', 'cache-control'];
                const h = Object.fromEntries(keep.filter((k) => k in res.headers).map((k) => [k, res.headers[k]]));
                // A 304 to HEAD: upstream's response writer always sets
                // Content-Length (0 here); send leaves it out. Not compared.
                if (res.statusCode === 304) delete h['content-length'];
                h.etag = 'etag' in res.headers;
                h['last-modified'] = 'last-modified' in res.headers;
                t.note(`raw ${name}`, { status: res.statusCode, headers: h, body: Buffer.concat(chunks).toString('utf8') });
                resolve();
            });
        });
        req.on('error', (e) => { t.note(`raw ${name}`, { error: e.message }); resolve(); });
        req.end();
    });
}

export async function scenario(t) {
    const html = { accept: 'text/html,application/xhtml+xml,*/*;q=0.8' };
    const get = (name, path, headers = {}, method = 'GET') => t.req(name, method, path, { headers });

    // The server check: GET / not asking for HTML.
    await get('root no accept', '/');
    await get('root accept any', '/', { accept: '*/*' });
    await get('root accept json', '/', { accept: 'application/json' });
    await get('root accept html', '/', html);
    await get('root accept HTML upper', '/', { accept: 'TEXT/HTML' });
    await get('root query no accept', '/?x=1');
    await get('root query html', '/?x=1', html);
    await get('root head', '/', {}, 'HEAD');
    await get('root head html', '/', html, 'HEAD');
    await get('root post', '/', {}, 'POST');
    await get('double slash', '//', html);

    // Files.
    await get('index.html', '/index.html');
    await get('index.html html', '/index.html', html);
    await get('index.html query', '/index.html?v=2', html);
    await get('script', '/assets/app.js');
    await get('script head', '/assets/app.js', {}, 'HEAD');
    await get('style', '/style.css');
    await get('manifest', '/manifest.json');
    await get('spaced name', '/file%20with%20space.txt');
    await get('nested dir slash', '/nested/', html);
    await get('nested dir', '/nested', html);
    await get('nested index', '/nested/index.html');
    await get('assets dir', '/assets/');
    await get('dotfile', '/.hidden');
    await get('traversal', '/../package.json');
    await get('encoded traversal', '/%2e%2e/%2e%2e/package.json');
    await get('encoded slash', '/assets%2fapp.js');
    await get('null byte', '/assets/app.js%00');
    await get('bad escape', '/%zz');

    // Conditional and partial requests.
    const first = await fetch(t.base + '/assets/app.js');
    const etag = first.headers.get('etag');
    const lastModified = first.headers.get('last-modified');
    t.note('validators', { etag: typeof etag, weak: etag?.startsWith('W/'), lastModified: typeof lastModified, ranges: first.headers.get('accept-ranges') });
    if (etag) {
        await get('if-none-match', '/assets/app.js', { 'if-none-match': etag });
        await get('if-none-match list', '/assets/app.js', { 'if-none-match': `"x", ${etag}` });
        await get('if-none-match other', '/assets/app.js', { 'if-none-match': '"x"' });
    }
    if (lastModified) await get('if-modified-since', '/assets/app.js', { 'if-modified-since': lastModified });
    await get('range', '/assets/app.js', { range: 'bytes=0-6' });

    // The same without fetch's no-cache.
    const js = '/assets/app.js';
    const day = (d) => new Date(Date.now() + d * 86400e3).toUTCString();
    if (etag) {
        await raw(t, 'if-none-match', js, { 'if-none-match': etag });
        await raw(t, 'if-none-match head', js, { 'if-none-match': etag }, 'HEAD');
        await raw(t, 'if-none-match strong', js, { 'if-none-match': etag.slice(2) });
        await raw(t, 'if-none-match list', js, { 'if-none-match': `"x",${etag}` });
        await raw(t, 'if-none-match other', js, { 'if-none-match': '"x"' });
        await raw(t, 'if-none-match star', js, { 'if-none-match': '*' });
        await raw(t, 'if-none-match no-cache', js, { 'if-none-match': etag, 'cache-control': 'no-cache' });
        await raw(t, 'if-none-match beats if-modified-since', js, { 'if-none-match': '"x"', 'if-modified-since': day(1) });
        await raw(t, 'if-none-match index', '/', { 'if-none-match': '*', accept: 'text/html' });
        await raw(t, 'if-match ok', js, { 'if-match': etag });
        await raw(t, 'if-match star', js, { 'if-match': '*' });
        await raw(t, 'if-match other', js, { 'if-match': '"x"' });
        await raw(t, 'if-range etag', js, { range: 'bytes=0-6', 'if-range': etag });
        await raw(t, 'if-range other etag', js, { range: 'bytes=0-6', 'if-range': '"x"' });
    }
    if (lastModified) {
        await raw(t, 'if-modified-since same', js, { 'if-modified-since': lastModified });
        await raw(t, 'if-modified-since later', js, { 'if-modified-since': day(1) });
        await raw(t, 'if-modified-since earlier', js, { 'if-modified-since': day(-36500) });
        await raw(t, 'if-modified-since junk', js, { 'if-modified-since': 'junk' });
        await raw(t, 'if-unmodified-since earlier', js, { 'if-unmodified-since': day(-36500) });
        await raw(t, 'if-unmodified-since later', js, { 'if-unmodified-since': day(1) });
        await raw(t, 'if-range date', js, { range: 'bytes=0-6', 'if-range': lastModified });
        await raw(t, 'if-range old date', js, { range: 'bytes=0-6', 'if-range': day(-36500) });
    }
    for (const r of ['bytes=0-6', 'bytes=-5', 'bytes=3-', 'bytes=2-1000', 'bytes=1000-2000', 'bytes=0-1,4-5', 'bytes=0-3,2-6', 'bytes=x', 'items=0-1', ' bytes=0-0']) {
        await raw(t, `range ${r}`, js, { range: r });
    }
    await raw(t, 'range head', js, { range: 'bytes=0-6' }, 'HEAD');
    await raw(t, 'range index', '/', { range: 'bytes=0-5', accept: 'text/html' });

    // The SPA fallback and what it leaves alone.
    await get('route', '/sessions/abc', html);
    await get('route no accept', '/settings');
    await get('missing asset', '/assets/missing.js');
    await get('route head', '/sessions/abc', {}, 'HEAD');
    await get('route post', '/sessions/abc', {}, 'POST');
    await get('route delete', '/sessions/abc', {}, 'DELETE');
    for (const p of ['/v1', '/v1/nope', '/v1x', '/v3/nope', '/v2/nope', '/socket.io/', '/files/x', '/metrics', '/healthz', '/health', '/v1/updates']) {
        await get(`api path ${p}`, p, html);
    }

    // API routes still answer.
    const token = await login(t, 1);
    await get('api route', '/v1/sessions', { authorization: 'Bearer ' + token });
    await get('api route no auth', '/v1/sessions');
}

export function normalize(s) {
    return s;
}
