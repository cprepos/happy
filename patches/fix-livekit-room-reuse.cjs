/**
 * Restores pristine @livekit/components-react on installs that still carry an
 * older patch from this file. That patch added `token` to the Room creation
 * effect deps in useLiveKitRoom, which raced with provider re-keying (two Rooms
 * overlapping, fingerprint mismatch errors). Re-keying the provider in app code
 * handles stale Room reuse cleanly, so the original deps are what we want.
 * pnpm hard-links node_modules files to its store, so an in-place edit can
 * outlive a reinstall; this revert is idempotent and a no-op on clean installs.
 */
const fs = require('fs');
const path = require('path');

let patched = 0;

const nodeModulesRoots = [
    path.resolve(__dirname, '..', 'node_modules'),
    path.resolve(__dirname, '..', 'packages/happy-app/node_modules'),
];

// --- Revert prior token-in-deps patch on @livekit/components-react ---

for (const nodeModulesRoot of nodeModulesRoots) {
    // ESM bundle: revert `[r, JSON.stringify(t, T), e]` back to `[r, JSON.stringify(t, T)]`
    const esmFile = path.join(
        nodeModulesRoot,
        '@livekit/components-react/dist/room-Bb6uLxS5.mjs'
    );
    if (fs.existsSync(esmFile)) {
        let content = fs.readFileSync(esmFile, 'utf8');
        const original = content;
        content = content.replace(
            /O\(r \?\? new U\(t\)\);\s*\}, \[r, JSON\.stringify\(t, T\), e\]\)/,
            'O(r ?? new U(t));\n  }, [r, JSON.stringify(t, T)])'
        );
        if (content !== original) {
            fs.writeFileSync(esmFile, content, 'utf8');
            patched++;
        }
    }

    // CJS bundle: revert the same
    const cjsFile = path.join(
        nodeModulesRoot,
        '@livekit/components-react/dist/shared-BGiZtWPs.js'
    );
    if (fs.existsSync(cjsFile)) {
        let content = fs.readFileSync(cjsFile, 'utf8');
        const original = content;
        content = content.replace(
            /I\(f\?\?new d\.Room\(s\)\)\}\,\[f,JSON\.stringify\(s,M\.roomOptionsStringifyReplacer\),t\]\)/,
            'I(f??new d.Room(s))},[f,JSON.stringify(s,M.roomOptionsStringifyReplacer)])'
        );
        if (content !== original) {
            fs.writeFileSync(cjsFile, content, 'utf8');
            patched++;
        }
    }

    // Source file: revert
    const srcFile = path.join(
        nodeModulesRoot,
        '@livekit/components-react/src/hooks/useLiveKitRoom.ts'
    );
    if (fs.existsSync(srcFile)) {
        let content = fs.readFileSync(srcFile, 'utf8');
        const original = content;
        content = content.replace(
            '}, [passedRoom, JSON.stringify(options, roomOptionsStringifyReplacer), token]);',
            '}, [passedRoom, JSON.stringify(options, roomOptionsStringifyReplacer)]);'
        );
        if (content !== original) {
            fs.writeFileSync(srcFile, content, 'utf8');
            patched++;
        }
    }
}

if (patched > 0) {
    console.log(`[patch] Restored @livekit/components-react Room deps (${patched} file(s))`);
}
