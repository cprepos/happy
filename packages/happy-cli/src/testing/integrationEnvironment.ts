import { existsSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const REPO_ROOT = resolve(__dirname, '..', '..', '..', '..');
const ENVIRONMENTS_MODULE_URL = pathToFileURL(join(REPO_ROOT, 'packages', 'dev-environments', 'environments.ts')).href;

export type EnvironmentTemplate = 'authenticated-empty' | 'empty';

export type IntegrationEnvironment = {
    name: string;
    envDir: string;
    projectPath: string;
    serverPort: number;
    expoPort: number;
};

type EnvironmentConfig = {
    projectPath: string;
    serverPort: number;
    expoPort: number;
};

type EnvironmentsModule = {
    createEnvironment: (opts?: { noSwitch?: boolean }) => Promise<string>;
    getEnvironmentConfig: (name: string) => EnvironmentConfig;
    getEnvironmentDir: (name: string) => string;
    removeEnvironment: (name: string) => void;
    seedEnvironment: (name: string) => Promise<void>;
    setEnvironmentTemplate: (name: string, template: EnvironmentTemplate) => void;
    startEnvironmentServices: (name: string) => Promise<void>;
    stopEnvironment: (name: string) => void;
};

async function loadEnvironmentManager(): Promise<EnvironmentsModule> {
    return await import(ENVIRONMENTS_MODULE_URL) as EnvironmentsModule;
}

export async function createIntegrationEnvironment(options?: {
    template?: EnvironmentTemplate;
    up?: boolean;
    /** Called with the name as soon as the environment exists, before any service starts. */
    onCreated?: (name: string) => void;
}): Promise<IntegrationEnvironment> {
    const template = options?.template ?? 'authenticated-empty';
    const shouldStart = options?.up ?? true;
    const environments = await loadEnvironmentManager();
    const name = await environments.createEnvironment({ noSwitch: true });
    options?.onCreated?.(name);

    try {
        environments.setEnvironmentTemplate(name, template);

        if (shouldStart) {
            await environments.startEnvironmentServices(name);
            if (template === 'authenticated-empty') {
                await environments.seedEnvironment(name);
            }
        }

        const config = environments.getEnvironmentConfig(name);
        return {
            name,
            envDir: environments.getEnvironmentDir(name),
            projectPath: config.projectPath,
            serverPort: config.serverPort,
            expoPort: config.expoPort,
        };
    } catch (error) {
        try {
            environments.stopEnvironment(name);
        } catch {}

        try {
            environments.removeEnvironment(name);
        } catch {}

        throw error;
    }
}

export function applyEnvironmentToProcess(env: IntegrationEnvironment) {
    process.env.HAPPY_SERVER_URL = `http://localhost:${env.serverPort}`;
    process.env.HAPPY_WEBAPP_URL = `http://localhost:${env.expoPort}`;
    process.env.HAPPY_HOME_DIR = join(env.envDir, 'cli', 'home');
    process.env.HAPPY_PROJECT_DIR = env.projectPath;
    process.env.HAPPY_VARIANT = 'dev';
    process.env.DEBUG = '1';
}

export async function destroyIntegrationEnvironment(env: IntegrationEnvironment) {
    const environments = await loadEnvironmentManager();
    environments.stopEnvironment(env.name);
    environments.removeEnvironment(env.name);
}

// A file's afterAll does not run when every test in it is skipped, which is
// what happens on any machine without the agent it tests. Each environment is
// therefore also recorded in a per-run ledger, and the global teardown destroys
// whatever is still recorded there.

export function recordIntegrationEnvironment(ledgerDir: string, name: string) {
    writeFileSync(join(ledgerDir, name), name);
}

export function forgetIntegrationEnvironment(ledgerDir: string, name: string) {
    rmSync(join(ledgerDir, name), { force: true });
}

export async function destroyRecordedIntegrationEnvironments(ledgerDir: string) {
    if (!existsSync(ledgerDir)) {
        return;
    }

    const environments = await loadEnvironmentManager();
    for (const name of readdirSync(ledgerDir)) {
        if (existsSync(environments.getEnvironmentDir(name))) {
            try {
                environments.stopEnvironment(name);
            } finally {
                environments.removeEnvironment(name);
            }
        }
        forgetIntegrationEnvironment(ledgerDir, name);
    }
}
