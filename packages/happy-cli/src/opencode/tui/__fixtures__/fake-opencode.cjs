#!/usr/bin/env node
// Stand-in for the `opencode` binary in process lifecycle tests.
//   serve   -> listens on 127.0.0.1, prints the address like opencode does,
//              exits on SIGTERM (unless FAKE_IGNORE_TERM=1)
//   attach  -> writes its argv and password to FAKE_ATTACH_OUT, exits with FAKE_EXIT_CODE
//   crash   -> exits 3 before becoming ready
const http = require('node:http');
const fs = require('node:fs');

const mode = process.argv[2];
if (mode === 'serve') {
    const server = http.createServer((req, res) => res.end('{}'));
    server.listen(0, '127.0.0.1', () => {
        console.log(`opencode server listening on http://127.0.0.1:${server.address().port}`);
    });
    process.on('SIGTERM', () => {
        if (process.env.FAKE_IGNORE_TERM === '1') return;
        process.exit(0);
    });
    setInterval(() => { }, 1000);
} else if (mode === 'attach') {
    fs.writeFileSync(process.env.FAKE_ATTACH_OUT, JSON.stringify({
        argv: process.argv.slice(2),
        password: process.env.OPENCODE_SERVER_PASSWORD,
    }));
    process.exit(Number(process.env.FAKE_EXIT_CODE || 0));
} else {
    console.error('boom');
    process.exit(3);
}
