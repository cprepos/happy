package com.slopus.happy.browser

import com.slopus.happy.connection.TransportSocket
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.isActive

/**
 * iOS's `BrowserConnectionPool`: one page's keep-alive connections to the
 * computer, for its artifact API. A lease is exclusive and never pipelined,
 * and goes back only after a complete, self-delimited answer
 * ([BrowserResponseBody.reusable]). At most [MAX_IDLE] wait, each for
 * [IDLE_MILLIS]; stopping closes idle and leased ones alike.
 */
internal class BrowserConnectionPool(
    /** A new connection and the credential to use on it. */
    private val open: suspend () -> Pair<TransportSocket, String>,
    private val now: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    class Lease internal constructor(val socket: TransportSocket, val token: String)

    private class Idle(val lease: Lease, val since: Long)

    private val idle = ArrayDeque<Idle>()
    private val leased = mutableSetOf<Lease>()
    private var stopped = false

    /** An idle connection if [reusing] and one is fresh, else a new one. */
    suspend fun take(reusing: Boolean = true): Lease {
        val stale = mutableListOf<Lease>()
        val reused = synchronized(this) {
            if (stopped) throw CancellationException("pool stopped")
            var found: Lease? = null
            while (reusing && found == null) {
                val candidate = idle.removeLastOrNull() ?: break
                if (now() - candidate.since < IDLE_MILLIS) found = candidate.lease else stale += candidate.lease
            }
            found?.also { leased += it }
        }
        stale.forEach { it.socket.close() }
        if (reused != null) return reused
        val (socket, token) = open()
        val lease = Lease(socket, token)
        val active = currentCoroutineContext().isActive
        val kept = synchronized(this) { (!stopped && active).also { if (it) leased += lease } }
        if (!kept) {
            socket.close()
            throw CancellationException("pool stopped")
        }
        return lease
    }

    /** Returns [lease]: kept for the next request if [reusable], else closed. Safe in a `finally` of a cancelled coroutine. */
    fun release(lease: Lease, reusable: Boolean) {
        val keep = synchronized(this) {
            if (!leased.remove(lease)) return
            (reusable && !stopped && idle.size < MAX_IDLE).also { if (it) idle.addLast(Idle(lease, now())) }
        }
        if (!keep) lease.socket.close()
    }

    fun stop() {
        val all = synchronized(this) {
            stopped = true
            (idle.map { it.lease } + leased).also {
                idle.clear()
                leased.clear()
            }
        }
        all.forEach { it.socket.close() }
    }

    companion object {
        const val MAX_IDLE = 6
        const val IDLE_MILLIS = 5_000L
    }
}
