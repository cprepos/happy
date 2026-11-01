package com.slopus.happy.browser

import com.slopus.happy.connection.AgentConnectionException
import com.slopus.happy.connection.TransportSocket
import io.tailcat.stack.TailcatTransportException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotSame
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/** iOS's `BrowserResponseTests`: answer framing for pooling, the pool itself, and the failures it distinguishes. */
class BrowserResponseTest {
    private fun head(fields: String, status: Int = 200) = HttpHead.parse("HTTP/1.1 $status Test\r\n$fields\r\n".toByteArray())!!.first

    private fun malformed(block: () -> Unit) {
        try {
            block()
            fail("expected a BrowserException")
        } catch (_: BrowserException) {
        }
    }

    @Test fun contentLengthCompletesWithoutWaitingForEof() {
        val body = BrowserResponseBody(head("Content-Length: 5\r\n"), "GET")
        body.append("he".toByteArray())
        assertFalse(body.finished)
        body.append("llo".toByteArray())
        assertTrue(body.finished)
        assertTrue(body.reusable)
        malformed { body.append("extra".toByteArray()) }
    }

    @Test fun chunkedBodyConsumesEveryTrailerBeforeReuse() {
        val bytes = "3;ext=yes\r\none\r\n3\r\ntwo\r\n0\r\nETag: trailing\r\n\r\n".toByteArray()
        for (split in 0..bytes.size) {
            val body = BrowserResponseBody(head("Transfer-Encoding: chunked\r\n"), "GET")
            body.append(bytes.copyOfRange(0, split))
            assertEquals(split == bytes.size, body.finished)
            body.append(bytes.copyOfRange(split, bytes.size))
            assertTrue(body.finished)
            assertTrue(body.reusable)
        }
        val bytewise = BrowserResponseBody(head("Transfer-Encoding: chunked\r\n"), "GET")
        for (byte in bytes) bytewise.append(byteArrayOf(byte))
        assertTrue(bytewise.finished)
    }

    @Test fun closeDelimitedResponsesAndConnectionCloseAreNotPooled() {
        val close = BrowserResponseBody(head(""), "GET")
        close.append("stream".toByteArray())
        assertFalse(close.finished)
        close.end()
        assertTrue(close.finished)
        assertFalse(close.reusable)
        val length = BrowserResponseBody(head("Content-Length: 0\r\nConnection: keep-alive, Close\r\n"), "GET")
        length.end()
        assertTrue(length.finished)
        assertFalse(length.reusable)
        val http10 = HttpHead.parse("HTTP/1.0 200 OK\r\nContent-Length: 0\r\n\r\n".toByteArray())!!.first
        assertFalse(BrowserResponseBody(http10, "GET").reusable)
    }

    @Test fun headAndNoBodyStatusesDoNotConsumeAdvertisedLength() {
        for ((method, code) in listOf("HEAD" to 200, "GET" to 204, "GET" to 304)) {
            val body = BrowserResponseBody(head("Content-Length: 900\r\n", code), method)
            assertTrue(body.finished)
            assertTrue(body.reusable)
        }
    }

    @Test fun malformedTruncatedAndAmbiguousBodiesAreNotReusable() {
        for (fields in listOf("Content-Length: 1\r\nContent-Length: 1\r\n", "Content-Length: 1\r\nTransfer-Encoding: chunked\r\n", "Content-Length: -1\r\n", "Transfer-Encoding: gzip\r\n")) {
            malformed { BrowserResponseBody(head(fields), "GET") }
        }
        for (wire in listOf("Z\r\n", "2\r\nabXX", "0\r\nInvalid-Trailer\r\n\r\n", "0\r\n\r\nextra")) {
            val body = BrowserResponseBody(head("Transfer-Encoding: chunked\r\n"), "GET")
            malformed { body.append(wire.toByteArray()) }
        }
        for (fields in listOf("Content-Length: 5\r\n", "Transfer-Encoding: chunked\r\n")) {
            val body = BrowserResponseBody(head(fields), "GET")
            malformed { body.end() }
        }
    }

    @Test fun tailcatCapacityIsDistinguishedFromTransport() {
        val limit = AgentConnectionException(AgentConnectionException.Reason.Unavailable)
            .initCause(TailcatTransportException(TailcatTransportException.Reason.RESOURCE_LIMIT))
        val capacity = BrowserFailure.of(BrowserUpstreamException(limit))
        assertEquals(503, capacity.status)
        assertEquals("browser_proxy_upstream_capacity", capacity.code)
        val closed = AgentConnectionException(AgentConnectionException.Reason.Unavailable)
            .initCause(TailcatTransportException(TailcatTransportException.Reason.CLOSED))
        assertEquals("browser_proxy_upstream_transport", BrowserFailure.of(BrowserUpstreamException(closed)).code)
        assertEquals("browser_proxy_socket_transport", BrowserFailure.of(java.io.IOException("reset")).code)
    }

    private class Stream : TransportSocket {
        var closed = false
        override suspend fun read(maximumBytes: Int) = ByteArray(0)
        override suspend fun write(bytes: ByteArray) {}
        override fun close() {
            closed = true
        }
    }

    @Test fun poolLeasesExclusivelyAndClosesOnStop() = runBlocking {
        val opened = mutableListOf<Stream>()
        val pool = BrowserConnectionPool({ Stream().also { opened += it } to "token" })
        val first = pool.take()
        val second = pool.take()
        assertEquals(2, opened.size)
        pool.release(first, reusable = true)
        val reused = pool.take()
        assertSame(first.socket, reused.socket)
        assertNotSame(second.socket, reused.socket)
        assertEquals("token", reused.token)
        pool.release(reused, reusable = false)
        assertTrue(opened[0].closed)
        pool.stop()
        assertTrue(opened[1].closed)
        try {
            pool.take()
            fail("A stopped pool reopened")
        } catch (_: CancellationException) {
        }
    }

    @Test fun poolBoundsIdleConnections() = runBlocking {
        val opened = mutableListOf<Stream>()
        val pool = BrowserConnectionPool({ Stream().also { opened += it } to "token" })
        val leases = List(10) { pool.take() }
        leases.forEach { pool.release(it, reusable = true) }
        assertEquals(4, opened.count { it.closed })
        pool.stop()
        assertTrue(opened.all { it.closed })
    }

    @Test fun poolDropsStaleIdleAndNeverReusesForAFreshLease() = runBlocking {
        var clock = 0L
        val opened = mutableListOf<Stream>()
        val pool = BrowserConnectionPool({ Stream().also { opened += it } to "token" }, now = { clock })
        val first = pool.take()
        pool.release(first, reusable = true)
        // A non-API request never takes an idle connection.
        val fresh = pool.take(reusing = false)
        assertNotSame(first.socket, fresh.socket)
        clock += BrowserConnectionPool.IDLE_MILLIS
        val after = pool.take()
        assertTrue(opened[0].closed)
        assertNotSame(first.socket, after.socket)
        // A lease released twice goes back once.
        pool.release(after, reusable = true)
        pool.release(after, reusable = true)
        assertSame(after.socket, pool.take().socket)
        assertEquals(3, opened.size)
        pool.stop()
    }
}
