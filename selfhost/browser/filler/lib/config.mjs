// Filler settings. Secrets are read from files under $FILLER_HOME/secrets
// (/srv/happy-filler/secrets on the host, 1990 0500, files 0400), never from
// argv or environment values.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export function loadConfig(env = process.env) {
    const home = env.FILLER_HOME || '/filler';
    const secrets = join(home, 'secrets');
    const testLoopback = env.FILLER_TEST_ALLOW_LOOPBACK_HTTP === '1';
    return {
        home,
        host: env.FILLER_HOST || '127.0.0.1',
        port: Number(env.FILLER_PORT || 6091),
        vaultUrl: env.VAULT_URL || 'http://127.0.0.1:8222',
        autoBrowserUrl: env.AUTO_BROWSER_URL || 'http://127.0.0.1:8010',
        policyPath: env.FILLER_POLICY || join(home, 'policy.json'),
        statePath: join(home, 'state', 'taint.json'),
        auditDir: join(home, 'audit'),
        // Smoke tests only: fill into http://127.0.0.1 pages and accept a
        // policy not owned by root. Never set in compose.filler.yml.
        testLoopback,
        files: {
            clientTokenSha256: join(secrets, 'client-token.sha256'),
            controllerToken: join(secrets, 'controller-token'),
            vaultClientId: join(secrets, 'vault-client-id'),
            vaultClientSecret: join(secrets, 'vault-client-secret'),
            vaultUserKey: join(secrets, 'vault-user-key'),
            vaultDeviceId: join(secrets, 'vault-device-id'),
            vaultEmail: join(secrets, 'vault-email'),
        },
    };
}

export function readSecret(path) {
    const v = readFileSync(path, 'utf8').trim();
    if (!v) throw new Error(`empty secret file ${path}`);
    return v;
}

export function readSecretOrNull(path) {
    try { return readSecret(path); } catch { return null; }
}
