import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { SESSION_SCOPED_ENV_KEYS } from './sessionEnvironment'

const mocks = vi.hoisted(() => ({
  mockLoggerDebug: vi.fn(),
  mockIsDaemonRunningCurrentlyInstalledHappyVersion: vi.fn(),
  mockCheckIfDaemonRunningAndCleanupStaleState: vi.fn(),
  mockSpawnHappyCLI: vi.fn(),
  mockReadDaemonState: vi.fn(),
  mockExecFileSync: vi.fn(),
  mockLoggerWarn: vi.fn(),
}))

vi.mock('@/persistence', () => ({
  readDaemonState: mocks.mockReadDaemonState,
}))

vi.mock('node:child_process', async (importOriginal) => ({
  ...(await importOriginal<typeof import('node:child_process')>()),
  execFileSync: mocks.mockExecFileSync,
}))

vi.mock('@/ui/logger', () => ({
  logger: {
    debug: mocks.mockLoggerDebug,
    warn: mocks.mockLoggerWarn,
  },
}))

vi.mock('./controlClient', () => ({
  isDaemonRunningCurrentlyInstalledHappyVersion: mocks.mockIsDaemonRunningCurrentlyInstalledHappyVersion,
  checkIfDaemonRunningAndCleanupStaleState: mocks.mockCheckIfDaemonRunningAndCleanupStaleState,
}))

vi.mock('@/utils/spawnHappyCLI', () => ({
  spawnHappyCLI: mocks.mockSpawnHappyCLI,
}))

import { ensureDaemonRunning } from './ensureDaemonRunning'

describe('ensureDaemonRunning', () => {
  afterEach(() => {
    vi.unstubAllEnvs()
  })

  beforeEach(() => {
    vi.clearAllMocks()
    mocks.mockSpawnHappyCLI.mockReturnValue({
      unref: vi.fn(),
    })
    mocks.mockCheckIfDaemonRunningAndCleanupStaleState.mockResolvedValue(true)
    mocks.mockReadDaemonState.mockResolvedValue(null)
    vi.stubEnv('HAPPY_DAEMON_SUPERVISOR', '')
    vi.stubEnv('XPC_SERVICE_NAME', '')
  })

  it('returns without spawning when the daemon is already running', async () => {
    mocks.mockIsDaemonRunningCurrentlyInstalledHappyVersion.mockResolvedValue(true)

    await ensureDaemonRunning()

    expect(mocks.mockSpawnHappyCLI).not.toHaveBeenCalled()
    expect(mocks.mockCheckIfDaemonRunningAndCleanupStaleState).not.toHaveBeenCalled()
    expect(mocks.mockLoggerDebug).toHaveBeenCalledWith(
      'Ensuring Happy background service is running & matches our version...',
    )
  })

  it('starts the daemon and waits for readiness when the installed version is not running', async () => {
    const mockUnref = vi.fn()
    mocks.mockIsDaemonRunningCurrentlyInstalledHappyVersion.mockResolvedValue(false)
    mocks.mockSpawnHappyCLI.mockReturnValue({
      unref: mockUnref,
    })
    mocks.mockCheckIfDaemonRunningAndCleanupStaleState
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true)

    for (const key of SESSION_SCOPED_ENV_KEYS) {
      vi.stubEnv(key, `stale-${key}`)
    }
    vi.stubEnv('HAPPY_SAFE_ENV', 'kept')

    await ensureDaemonRunning()

    expect(mocks.mockSpawnHappyCLI).toHaveBeenCalledWith(['daemon', 'start-sync'], expect.objectContaining({
      detached: true,
      stdio: 'ignore',
      env: expect.objectContaining({ HAPPY_SAFE_ENV: 'kept' }),
    }))
    const spawnedEnv = mocks.mockSpawnHappyCLI.mock.calls[0][1].env
    for (const key of SESSION_SCOPED_ENV_KEYS) {
      expect(spawnedEnv).not.toHaveProperty(key)
    }
    expect(mockUnref).toHaveBeenCalled()
    expect(mocks.mockCheckIfDaemonRunningAndCleanupStaleState).toHaveBeenCalledTimes(2)
    expect(mocks.mockLoggerDebug).toHaveBeenCalledWith('Starting Happy background service...')
    expect(mocks.mockLoggerDebug).toHaveBeenCalledWith('Happy background service is ready')
  })

  it.each([
    ['launchd:com.happy.cli-daemon', 'launchctl', ['kickstart', '-k', `gui/${process.getuid?.() ?? 0}/com.happy.cli-daemon`]],
    ['systemd:happy-cli-daemon.service', 'systemctl', ['--user', 'restart', 'happy-cli-daemon.service']],
  ])('restarts a %s daemon through its service manager instead of spawning one', async (supervisor, file, args) => {
    mocks.mockReadDaemonState.mockResolvedValue({ pid: 4321, httpPort: 1, startTime: '', startedWithCliVersion: 'old', supervisor })
    mocks.mockIsDaemonRunningCurrentlyInstalledHappyVersion
      .mockResolvedValueOnce(false)
      .mockResolvedValueOnce(true)

    await ensureDaemonRunning()

    expect(mocks.mockExecFileSync).toHaveBeenCalledWith(file, args, expect.any(Object))
    expect(mocks.mockSpawnHappyCLI).not.toHaveBeenCalled()
  })

  it('falls back to spawning, loudly, when the service manager refuses', async () => {
    mocks.mockReadDaemonState.mockResolvedValue({ pid: 4321, httpPort: 1, startTime: '', startedWithCliVersion: 'old', supervisor: 'launchd:com.happy.cli-daemon' })
    mocks.mockIsDaemonRunningCurrentlyInstalledHappyVersion.mockResolvedValue(false)
    mocks.mockExecFileSync.mockImplementation(() => { throw new Error('Could not find service') })

    await ensureDaemonRunning()

    expect(mocks.mockLoggerWarn).toHaveBeenCalledWith(expect.stringContaining('SUPERVISOR RESTART FAILED'), expect.any(Error))
    expect(mocks.mockSpawnHappyCLI).toHaveBeenCalledWith(['daemon', 'start-sync'], expect.any(Object))
  })

  it('does not ask the service manager when this process is that service', async () => {
    vi.stubEnv('HAPPY_DAEMON_SUPERVISOR', 'systemd:happy-cli-daemon.service')
    mocks.mockReadDaemonState.mockResolvedValue({ pid: 4321, httpPort: 1, startTime: '', startedWithCliVersion: 'old', supervisor: 'systemd:happy-cli-daemon.service' })
    mocks.mockIsDaemonRunningCurrentlyInstalledHappyVersion.mockResolvedValue(false)

    await ensureDaemonRunning()

    expect(mocks.mockExecFileSync).not.toHaveBeenCalled()
    expect(mocks.mockSpawnHappyCLI).toHaveBeenCalledTimes(1)
  })
})
