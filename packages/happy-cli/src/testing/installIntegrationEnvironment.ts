import { afterAll, inject } from 'vitest';
import {
    applyEnvironmentToProcess,
    createIntegrationEnvironment,
    destroyIntegrationEnvironment,
    forgetIntegrationEnvironment,
    recordIntegrationEnvironment,
    type EnvironmentTemplate,
    type IntegrationEnvironment,
} from './integrationEnvironment';

type IntegrationEnvironmentProfile = {
    template: EnvironmentTemplate;
    up: boolean;
};

declare global {
    // eslint-disable-next-line no-var
    var __happyIntegrationEnv: IntegrationEnvironment | undefined;
}

export async function installIntegrationEnvironment(profile: IntegrationEnvironmentProfile) {
    const previousEnv = {
        HAPPY_SERVER_URL: process.env.HAPPY_SERVER_URL,
        HAPPY_WEBAPP_URL: process.env.HAPPY_WEBAPP_URL,
        HAPPY_HOME_DIR: process.env.HAPPY_HOME_DIR,
        HAPPY_PROJECT_DIR: process.env.HAPPY_PROJECT_DIR,
        HAPPY_VARIANT: process.env.HAPPY_VARIANT,
        DEBUG: process.env.DEBUG,
    };

    // afterAll below never runs for a file whose tests are all skipped, so the
    // global teardown in src/test-setup.ts destroys whatever this ledger still lists.
    const ledgerDir = inject('integrationEnvironmentLedger');
    if (!ledgerDir) {
        throw new Error('No integration environment ledger; src/test-setup.ts must run as globalSetup');
    }

    const env = await createIntegrationEnvironment({
        ...profile,
        onCreated: (name) => recordIntegrationEnvironment(ledgerDir, name),
    });
    applyEnvironmentToProcess(env);
    globalThis.__happyIntegrationEnv = env;

    afterAll(async () => {
        try {
            await destroyIntegrationEnvironment(env);
            forgetIntegrationEnvironment(ledgerDir, env.name);
        } finally {
            for (const [key, value] of Object.entries(previousEnv)) {
                if (value === undefined) {
                    delete process.env[key];
                } else {
                    process.env[key] = value;
                }
            }

            if (globalThis.__happyIntegrationEnv?.name === env.name) {
                globalThis.__happyIntegrationEnv = undefined;
            }
        }
    });
}
