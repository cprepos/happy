package com.slopus.happy.model.settings

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import java.text.SimpleDateFormat
import java.util.TimeZone

/** account.tsx's push formatting. */
@RunWith(AndroidJUnit4::class)
class PushTextTest {
    private val resources = ApplicationProvider.getApplicationContext<android.app.Application>().resources

    @Test
    fun fingerprints() {
        assertEquals("abcdef…klmnop", PushText.fingerprint("ExponentPushToken[abcdefghijklmnop]"))
        assertEquals("short", PushText.fingerprint("ExponentPushToken[short]"))
        assertEquals("abcdefghijkl", PushText.fingerprint("abcdefghijkl"))
    }

    @Test
    fun permissionLabels() {
        fun text(id: Int) = resources.getString(id)
        assertEquals("Loading", text(PushText.label(null)))
        assertEquals("Not requested", text(PushText.label(PushPermission.Undetermined)))
        assertEquals("Unavailable", text(PushText.label(PushPermission(PushPermissionStatus.Unsupported, false, false))))
        assertEquals("Allowed", text(PushText.label(PushPermission(PushPermissionStatus.Granted, true, false))))
        assertEquals("Denied", text(PushText.label(PushPermission(PushPermissionStatus.Denied, false, true))))
        assertEquals("The system prompt can still be shown again from the app.", text(PushText.subtitle(PushPermission(PushPermissionStatus.Denied, false, true))))
        assertEquals("Opens system settings when the system will not prompt again.", text(PushText.requestSubtitle(PushPermission.Undetermined)))
    }

    @Test
    fun tokenSubtitles() {
        val format = SimpleDateFormat("yyyy-MM-dd HH:mm").apply { timeZone = TimeZone.getTimeZone("UTC") }
        val token = PushToken("pt1", "ExponentPushToken[abcdefghijklmnop]", createdAt = 0, updatedAt = 60_000)
        assertEquals(
            "Pixel 9 • Android 16\nHappy 0.1.0 • build 1\nRegistered: 1970-01-01 00:00\nLast seen: 1970-01-01 00:01\nServer ID: pt1\nToken: abcdef…klmnop",
            PushText.tokenSubtitle(resources, token, isCurrentDevice = true, deviceLabel = "Pixel 9 • Android 16", appLabel = "Happy 0.1.0 • build 1", format = format),
        )
        assertEquals(
            "Other device or stale registration\nRegistered: 1970-01-01 00:00\nLast seen: 1970-01-01 00:01\nServer ID: pt1\nToken: abcdef…klmnop",
            PushText.tokenSubtitle(resources, token, isCurrentDevice = false, deviceLabel = "x", appLabel = null, format = format),
        )
        assertEquals(
            "Ada's phone • Pixel 9 • Android 16" to "Happy 0.1.0 • build 1 • simulator",
            PushText.deviceLabels(resources, "Ada's phone", "Pixel 9", "16", "0.1.0", "1", emulator = true),
        )
        assertEquals("Pixel 9 • Android" to null, PushText.deviceLabels(resources, "Pixel 9", "Pixel 9", null, null, null, emulator = false))
    }
}
