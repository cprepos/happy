import { logger } from '@/ui/logger'
import { readDaemonState } from '@/persistence'
import { checkIfDaemonRunningAndCleanupStaleState, isDaemonRunningCurrentlyInstalledHappyVersion } from './controlClient'
import { spawnHappyCLI } from '@/utils/spawnHappyCLI'
import { sanitizeSessionEnvironment } from './sessionEnvironment'
import { detectDaemonSupervisor, restartSupervisedDaemon, type RestartSupervisedDaemonDeps } from './supervisor'

const DAEMON_READY_TIMEOUT_MS = 5000
const DAEMON_READY_POLL_INTERVAL_MS = 100
const SUPERVISED_READY_TIMEOUT_MS = 20_000

/**
 * When the running daemon is kept up by launchd or systemd and this process
 * is not that service, restart it through the service manager. Starting a
 * daemon here instead would put an unsupervised one beside the service, which
 * restarts its own and the two keep replacing each other.
 *
 * Returns true once a daemon of this CLI version is ready. Returns false when
 * there is no supervisor to ask, or asking failed, so the caller falls back
 * to starting one itself.
 */
export async function restartDaemonThroughSupervisor(
  supervisor: string | undefined,
  deps?: RestartSupervisedDaemonDeps,
): Promise<boolean> {
  if (!supervisor || supervisor === detectDaemonSupervisor()) return false

  try {
    logger.debug(`Restarting the Happy background service through its supervisor (${supervisor})`)
    restartSupervisedDaemon(supervisor, deps)
  } catch (error) {
    logger.warn(`[DAEMON] SUPERVISOR RESTART FAILED for ${supervisor}; falling back to starting an unsupervised daemon:`, error)
    return false
  }

  const deadline = Date.now() + SUPERVISED_READY_TIMEOUT_MS
  while (Date.now() < deadline) {
    if (await isDaemonRunningCurrentlyInstalledHappyVersion()) {
      logger.debug('Happy background service is ready (restarted by its supervisor)')
      return true
    }
    await new Promise(resolve => setTimeout(resolve, DAEMON_READY_POLL_INTERVAL_MS))
  }
  logger.warn(`[DAEMON] ${supervisor} did not bring up a current daemon within ${SUPERVISED_READY_TIMEOUT_MS}ms; falling back to starting an unsupervised daemon`)
  return false
}

export async function ensureDaemonRunning(): Promise<void> {
  logger.debug('Ensuring Happy background service is running & matches our version...')

  // Read before the version check, which clears the state of a dead daemon.
  const stateBefore = await readDaemonState()
  if (await isDaemonRunningCurrentlyInstalledHappyVersion()) {
    return
  }

  if (await restartDaemonThroughSupervisor(stateBefore?.supervisor)) {
    return
  }

  logger.debug('Starting Happy background service...')

  const daemonProcess = spawnHappyCLI(['daemon', 'start-sync'], {
    detached: true,
    stdio: 'ignore',
    env: sanitizeSessionEnvironment(process.env),
  })
  daemonProcess.unref()

  // Wait for the spawned daemon to be fully ready: it must write daemon.state.json,
  // bind its HTTP port, and respond to a health ping. Without this, early callers
  // (e.g. notifyDaemonSessionStarted) race the daemon startup and the webhook is
  // silently lost — which later breaks resume-happy-session.
  const deadline = Date.now() + DAEMON_READY_TIMEOUT_MS
  while (Date.now() < deadline) {
    if (await checkIfDaemonRunningAndCleanupStaleState()) {
      logger.debug('Happy background service is ready')
      return
    }
    await new Promise(resolve => setTimeout(resolve, DAEMON_READY_POLL_INTERVAL_MS))
  }

  logger.debug(`Happy background service did not become ready within ${DAEMON_READY_TIMEOUT_MS}ms; continuing anyway`)
}
