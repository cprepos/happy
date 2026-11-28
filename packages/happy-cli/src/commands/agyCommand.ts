import chalk from 'chalk'
import { authAndSetupMachineIfNeeded } from '@/ui/auth'
import { extractAgyResumeFlag } from '@/agy/cliArgs'
import { ensureDaemonRunning } from '@/daemon/ensureDaemonRunning'
import { isPermissionMode } from '@/claude/utils/permissionMode'
import type { PermissionMode } from '@/api/types'

export async function handleAgyCommand(args: string[]): Promise<void> {
  const { runAgy } = await import('@/agy/runAgy')

  const agyArgs = extractAgyResumeFlag(args)
  let startedBy: 'daemon' | 'terminal' | undefined = undefined
  let verbose = false
  let model: string | undefined = undefined
  let effort: string | undefined = undefined
  let permissionMode: PermissionMode | undefined = undefined
  for (let i = 0; i < agyArgs.args.length; i++) {
    const arg = agyArgs.args[i]
    const hasValue = i + 1 < agyArgs.args.length
    if (arg === '--started-by' && hasValue) {
      startedBy = agyArgs.args[++i] as 'daemon' | 'terminal'
    } else if (arg === '--happy-starting-mode' && hasValue) {
      i++
    } else if (arg === '--verbose') {
      verbose = true
    } else if (arg === '--model' && hasValue) {
      model = agyArgs.args[++i]
    } else if (arg === '--effort' && hasValue) {
      effort = agyArgs.args[++i]
    } else if (arg === '--permission-mode' && hasValue) {
      const value = agyArgs.args[++i]
      if (isPermissionMode(value)) {
        permissionMode = value
      } else {
        console.warn(chalk.yellow(`Ignoring unknown --permission-mode '${value}'`))
      }
    } else if (arg === '--yolo' || arg === '--dangerously-skip-permissions') {
      permissionMode = 'bypassPermissions'
    }
  }

  const { credentials } = await authAndSetupMachineIfNeeded()
  await ensureDaemonRunning()

  await runAgy({
    credentials,
    startedBy,
    verbose,
    model,
    effort,
    permissionMode,
    resumeConversationId: agyArgs.resumeConversationId ?? undefined,
  })
}
