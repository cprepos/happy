import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  mockAuthAndSetupMachineIfNeeded: vi.fn(),
  mockRunAgy: vi.fn(),
  mockEnsureDaemonRunning: vi.fn(),
}))

vi.mock('@/ui/auth', () => ({
  authAndSetupMachineIfNeeded: mocks.mockAuthAndSetupMachineIfNeeded,
}))

vi.mock('@/agy/runAgy', () => ({
  runAgy: mocks.mockRunAgy,
}))

vi.mock('@/daemon/ensureDaemonRunning', () => ({
  ensureDaemonRunning: mocks.mockEnsureDaemonRunning,
}))

import { handleAgyCommand } from './agyCommand'

describe('handleAgyCommand', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.mockAuthAndSetupMachineIfNeeded.mockResolvedValue({
      credentials: { token: 'token' },
    })
    mocks.mockEnsureDaemonRunning.mockResolvedValue(undefined)
    mocks.mockRunAgy.mockResolvedValue(undefined)
  })

  it('starts a fresh agy session without a conversation to resume', async () => {
    await handleAgyCommand(['--started-by', 'terminal'])

    expect(mocks.mockRunAgy).toHaveBeenCalledWith({
      credentials: { token: 'token' },
      startedBy: 'terminal',
      verbose: false,
      model: undefined,
      effort: undefined,
      permissionMode: undefined,
      resumeConversationId: undefined,
    })
    expect(
      mocks.mockEnsureDaemonRunning.mock.invocationCallOrder[0],
    ).toBeLessThan(mocks.mockRunAgy.mock.invocationCallOrder[0])
  })

  it('parses the daemon resume launch', async () => {
    // The shape buildResumeLaunch produces, plus the daemon's own flags.
    await handleAgyCommand([
      '--resume', 'conv-1', '--model', 'session-model', '--started-by', 'daemon',
      '--model', 'app-model', '--permission-mode', 'acceptEdits',
    ])

    expect(mocks.mockRunAgy).toHaveBeenCalledWith(expect.objectContaining({
      startedBy: 'daemon',
      resumeConversationId: 'conv-1',
      model: 'app-model',
      permissionMode: 'acceptEdits',
    }))
  })

  it('keeps values that follow other flags when --resume comes later', async () => {
    await handleAgyCommand(['--model', 'gemini', '--resume=conv-2', '--yolo'])

    expect(mocks.mockRunAgy).toHaveBeenCalledWith(expect.objectContaining({
      model: 'gemini',
      resumeConversationId: 'conv-2',
      permissionMode: 'bypassPermissions',
    }))
  })

  it.each([
    [['--resume']],
    [['--resume', '']],
    [['--resume', '--started-by', 'daemon']],
    [['--resume=']],
  ])('refuses %j before authenticating or starting a session', async (args) => {
    await expect(handleAgyCommand(args)).rejects.toThrow('Agy resume requires a conversation ID')

    expect(mocks.mockAuthAndSetupMachineIfNeeded).not.toHaveBeenCalled()
    expect(mocks.mockRunAgy).not.toHaveBeenCalled()
  })

  it('refuses a repeated --resume', async () => {
    await expect(handleAgyCommand(['--resume', 'a', '-r', 'b'])).rejects.toThrow(
      'Agy resume flag can only be provided once.',
    )
    expect(mocks.mockRunAgy).not.toHaveBeenCalled()
  })
})
