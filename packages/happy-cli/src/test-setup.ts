/**
 * Vitest global setup — runs once per project, before that project's tests.
 *
 * We build the CLI here. Integration suites provision their own isolated
 * environments so each suite can get a fresh lab-rat project copy. They clean
 * up in their own afterAll, but vitest skips that hook when every test in a
 * file is skipped, so each environment is also recorded in a ledger that the
 * teardown below empties.
 */

import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import type { TestProject } from 'vitest/node'
import { destroyRecordedIntegrationEnvironments } from './testing/integrationEnvironment'

declare module 'vitest' {
    export interface ProvidedContext {
        integrationEnvironmentLedger: string
    }
}

export async function setup(project: TestProject) {
    process.env.VITEST_POOL_TIMEOUT = '60000'
    process.env.HAPPY_RUN_SANDBOX_NETWORK_TESTS = '1'

    const ledgerDir = mkdtempSync(join(tmpdir(), 'happy-integration-envs-'))
    project.provide('integrationEnvironmentLedger', ledgerDir)

    const buildResult = spawnSync('pnpm', ['build'], { stdio: 'pipe' })
    if (buildResult.stderr && buildResult.stderr.length > 0) {
        const errorOutput = buildResult.stderr.toString()
        console.error(`Build stderr (could be debugger output): ${errorOutput}`)
        console.log(`Build stdout: ${buildResult.stdout.toString()}`)
        if (errorOutput.includes('Command failed with exit code')) {
            throw new Error(`Build failed STDERR: ${errorOutput}`)
        }
    }

    // Returned rather than exported: each project gets its own ledger, and a
    // closure keeps one project's teardown from reading another's.
    return async () => {
        try {
            await destroyRecordedIntegrationEnvironments(ledgerDir)
        } finally {
            rmSync(ledgerDir, { recursive: true, force: true })
        }
    }
}
