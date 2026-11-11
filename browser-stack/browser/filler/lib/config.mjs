// Filler settings. Secrets are read from files under $FILLER_HOME/secrets
// (FILLER_HOME=/filler in the container, the host's /srv/happy-filler; secrets/
// is uid 1990 0500, files 0400), never from argv or environment values.
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
        // The shared stack's controller, and the ports a request may name for a
        // per-chat pod's controller (127.0.0.1 only).
        controllerPort: Number(env.FILLER_CONTROLLER_PORT || 8010),
        controllerPorts: env.FILLER_CONTROLLER_PORTS || '8010,8100-8131',
        policyPath: env.FILLER_POLICY || join(home, 'policy.json'),
        statePath: join(home, 'state', 'taint.json'),
        auditDir: join(home, 'audit'),
        // Smoke tests only: fill into http://127.0.0.1 pages and accept a
        // policy owned by anyone. Never set in the compose service.
        testLoopback,
        files: {
            clientTokenSha256: join(secrets, 'client-token.sha256'),
            // vault-mcp's token, for /v1/vault/* only (the bridge's token never reaches those routes).
            vaultClientTokenSha256: join(secrets, 'vault-client-token.sha256'),
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
