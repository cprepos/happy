package com.slopus.happy.ui.settings

import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.ClipEntry
import androidx.compose.ui.platform.Clipboard
import androidx.compose.ui.platform.LocalClipboard
import androidx.compose.ui.platform.NativeClipboard
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsOff
import androidx.compose.ui.test.assertIsOn
import androidx.compose.ui.test.junit4.v2.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.slopus.happy.model.settings.PushPermission
import com.slopus.happy.model.settings.PushToken
import com.slopus.happy.ui.PHONE
import com.slopus.happy.ui.assertDp
import com.slopus.happy.ui.bounds
import com.slopus.happy.ui.components.ItemGroupTags
import com.slopus.happy.ui.node
import com.slopus.happy.ui.setHappyContent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode

/** Settings › Account and Backup & Restore, as iOS splits happy-app's Account page. */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = PHONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class AccountLayoutTest {
    @get:Rule
    val rule = createComposeRule()

    private val token = PushToken(id = "pt1", token = "ExponentPushToken[abcdefghijklmnop]", createdAt = 0, updatedAt = 0)

    private class RecordingClipboard(private val refuse: Boolean = false) : Clipboard {
        var text: String? = null
        override val nativeClipboard: NativeClipboard get() = error("unused")
        override suspend fun getClipEntry(): ClipEntry? = null
        override suspend fun setClipEntry(clipEntry: ClipEntry?) {
            if (refuse) throw SecurityException("denied")
            text = clipEntry?.clipData?.getItemAt(0)?.text?.toString()
        }
    }

    @Test
    fun whoTheAccountIsAndATapCopiesAnId() {
        val clipboard = RecordingClipboard()
        rule.setHappyContent {
            CompositionLocalProvider(LocalClipboard provides clipboard) {
                AccountScreen(
                    anonId = "0123456789abcdef", publicId = "cmabc",
                    analyticsOptOut = false, onAnalyticsOptOutChange = {}, onBack = {},
                    displayName = "Ada Lovelace", username = "ada",
                )
            }
        }
        for (text in listOf("Ada Lovelace", "@ada", "0123456789abcdef", "cmabc", "Happy Cloud", "Tap an ID to copy it.")) {
            rule.onNodeWithText(text).assertIsDisplayed()
        }
        rule.node(AccountTags.PUBLIC_ID).performClick()
        rule.waitForIdle()
        assertEquals("cmabc", clipboard.text)
        rule.onNodeWithText("Public ID copied to clipboard").assertIsDisplayed()
        // No titled groups, no key, no logout: those moved, as on iOS.
        rule.onAllNodesWithTag(ItemGroupTags.HEADER, useUnmergedTree = true).assertCountEquals(0)
        rule.onAllNodesWithText("Secret Key").assertCountEquals(0)
        rule.onAllNodesWithText("Logout").assertCountEquals(0)
    }

    @Test
    fun withoutIdsNothingIsCopiedAndTheServerIsNamed() {
        var optOut = true
        rule.setHappyContent {
            AccountScreen(anonId = null, publicId = null, analyticsOptOut = optOut, onAnalyticsOptOutChange = { optOut = it }, onBack = {}, server = "happy.example.com")
        }
        rule.onAllNodesWithText("Not available").assertCountEquals(2)
        rule.onNodeWithText("happy.example.com").assertIsDisplayed()
        rule.node(AccountTags.ANALYTICS_SWITCH).assertIsOff().performClick()
        assertEquals(false, optOut)
    }

    @Test
    fun analyticsIsOnUnlessOptedOut() {
        var optOut = false
        rule.setHappyContent {
            AccountScreen(anonId = null, publicId = null, analyticsOptOut = optOut, onAnalyticsOptOutChange = { optOut = it }, onBack = {})
        }
        rule.node(AccountTags.ANALYTICS_SWITCH).assertIsOn().performClick()
        assertTrue("switching analytics off opts out", optOut)
    }

    @Test
    fun pushRowsAndTokens() {
        val deleted = mutableListOf<String>()
        rule.setHappyContent {
            AccountScreen(
                anonId = null, publicId = null, analyticsOptOut = false, onAnalyticsOptOutChange = {}, onBack = {},
                push = PushState(permission = PushPermission.Undetermined, tokens = listOf(token)),
                onDeletePushToken = { deleted += it.id },
            )
        }
        rule.onNodeWithText("Not requested").performScrollTo().assertIsDisplayed()
        rule.onNodeWithText("Registered Tokens (1)", substring = true).performScrollTo().assertIsDisplayed()
        rule.onNodeWithText("abcdef…klmnop").performScrollTo().performClick()
        rule.onNodeWithText("Remove abcdef…klmnop from your account?").assertIsDisplayed()
        rule.onNodeWithText("Delete").performClick()
        assertEquals(listOf("pt1"), deleted)
    }

    @Test
    fun noTokensSaysSo() {
        rule.setHappyContent { AccountScreen(anonId = null, publicId = null, analyticsOptOut = false, onAnalyticsOptOutChange = {}, onBack = {}) }
        rule.onNodeWithText("No registered push tokens").performScrollTo().assertIsDisplayed()
        rule.onNodeWithText("Registered Tokens (0)", substring = true).performScrollTo().assertIsDisplayed()
    }

    @Test
    fun theKeyShowsOnATapAsACodeRowAndCopies() {
        val clipboard = RecordingClipboard()
        val key = "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE-FFFFF-GGGGG-HHHHH-IIIII-JJJJJ-KKKKK-LLLLL-M"
        rule.setHappyContent {
            CompositionLocalProvider(LocalClipboard provides clipboard) { BackupScreen(formattedSecretKey = key, onBack = {}) }
        }
        rule.onAllNodesWithTag(AccountTags.SECRET_KEY_TEXT, useUnmergedTree = true).assertCountEquals(0)
        rule.onNodeWithText("Show Secret Key").performClick()
        rule.onNodeWithText("Hide Secret Key").assertIsDisplayed()
        val card = rule.onAllNodesWithTag(ItemGroupTags.CARD, useUnmergedTree = true)[0].bounds
        val text = rule.node(AccountTags.SECRET_KEY_TEXT).bounds
        assertDp("the key the card's width", (card.right - card.left) - (2f / 3).dp, text.right - text.left)
        rule.node(AccountTags.COPY_SECRET_KEY).performClick()
        rule.waitForIdle()
        assertEquals(key, clipboard.text)
        rule.onNodeWithText("Secret key copied to clipboard. Store it in a safe place!").assertIsDisplayed()
    }

    @Test
    fun aRefusedKeyCopySaysSo() {
        // account.tsx handleCopySecret: a failed copy alerts instead of crashing.
        rule.setHappyContent {
            CompositionLocalProvider(LocalClipboard provides RecordingClipboard(refuse = true)) { BackupScreen(formattedSecretKey = "AAAAA", onBack = {}) }
        }
        rule.onNodeWithText("Show Secret Key").performClick()
        rule.node(AccountTags.SECRET_KEY_TEXT).performClick()
        rule.waitForIdle()
        rule.onNodeWithText("Failed to copy secret key").assertIsDisplayed()
    }

    @Test
    fun linkNewDeviceScansReadsScanningAndRestoreOpens() {
        var scans = 0
        var restores = 0
        var linking by mutableStateOf(false)
        rule.setHappyContent {
            BackupScreen(formattedSecretKey = "", onBack = {}, linkingDevice = linking, onLinkNewDevice = { scans++ }, onRestore = { restores++ })
        }
        rule.node(AccountTags.LINK_DEVICE).performClick()
        assertEquals(1, scans)
        linking = true
        rule.onNodeWithText("Scanning...").assertIsDisplayed()
        rule.node(AccountTags.LINK_DEVICE).performClick()
        assertEquals("a link in progress takes no taps", 1, scans)
        rule.node(AccountTags.RESTORE).performScrollTo().performClick()
        assertEquals(1, restores)
        rule.onNodeWithText("Scan the code another phone shows under Restore to sign it in to this account.").assertIsDisplayed()
    }
}
