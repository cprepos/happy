import { afterEach, describe, expect, it, vi } from 'vitest'

const { mockSdkQuery } = vi.hoisted(() => ({ mockSdkQuery: vi.fn() }))

vi.mock('@anthropic-ai/claude-agent-sdk', () => ({
    query: mockSdkQuery,
}))

import { query } from './query'

describe('query child environment', () => {
    const saved = { ...process.env }

    afterEach(() => {
        for (const key of Object.keys(process.env)) {
            if (!(key in saved)) delete process.env[key]
        }
        Object.assign(process.env, saved)
        mockSdkQuery.mockReset()
    })

    it('never passes session-scoped launch values to the agent', () => {
        process.env.HAPPY_RECONNECT_SESSION_ID = 'leaked-session'
        process.env.HAPPY_RECONNECT_ENCRYPTION_KEY = 'dummy'
        process.env.HAPPY_RECONNECT_ENCRYPTION_VARIANT = 'dataKey'
        process.env.CODEX_THREAD_ID = 'leaked-thread'
        process.env.HAPPY_SESSION_ID = 'bridge-session'

        query({ prompt: 'hi' })

        const env = mockSdkQuery.mock.calls[0][0].options.env as Record<string, string>
        expect(Object.keys(env).filter((key) => key.startsWith('HAPPY_RECONNECT_'))).toEqual([])
        expect(env).not.toHaveProperty('CODEX_THREAD_ID')
        expect(env.HAPPY_SESSION_ID).toBe('bridge-session')
        expect(env.HAPPY_MANAGED).toBe('1')
    })
})
