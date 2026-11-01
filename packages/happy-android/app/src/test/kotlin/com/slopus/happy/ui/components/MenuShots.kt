package com.slopus.happy.ui.components

import android.graphics.Bitmap
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.test.captureToImage
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.unit.dp
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.slopus.happy.ui.PHONE
import com.slopus.happy.ui.home.AccountMenu
import com.slopus.happy.ui.home.AccountMenuButton
import com.slopus.happy.ui.home.AccountMenuEntry
import com.slopus.happy.ui.home.AccountMenuTags
import com.slopus.happy.ui.node
import com.slopus.happy.ui.setHappyContent
import com.slopus.happy.ui.theme.HappyTheme
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

/**
 * Menus for review, written only when HAPPY_SHOTS_DIR is set: a stock
 * Material DropdownMenu built as the compose-chat target menu was before it
 * moved to [HappyDropdownMenu] (so the theme's defaults are what show), the
 * same menu in [HappyDropdownMenu], and the account menu; light and dark.
 */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = PHONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class MenuShots {
    @get:Rule val rule = createComposeRule()
    private val dir = System.getenv("HAPPY_SHOTS_DIR")?.let(::File)

    private fun save(name: String) {
        rule.mainClock.advanceTimeBy(1_000)
        rule.waitForIdle()
        val bitmap = rule.onRoot().captureToImage().asAndroidBitmap()
        File(dir, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    private fun show(dark: Boolean, menu: @Composable () -> Unit) {
        assumeTrue(dir != null)
        dir!!.mkdirs()
        rule.setHappyContent(dark) {
            Box(Modifier.fillMaxSize().padding(start = 60.dp, top = 120.dp)) {
                Text("Studio · happy", color = HappyTheme.colors.text)
                menu()
            }
        }
    }

    @Composable
    private fun Heading(title: String) {
        Text(title, style = MaterialTheme.typography.labelMedium, color = HappyTheme.colors.textSecondary, modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp))
    }

    @Composable
    private fun StockOption(name: String, selected: Boolean) {
        DropdownMenuItem(
            text = { Text(name) },
            trailingIcon = if (selected) ({ Icon(Ionicon.Checkmark, 20.dp, HappyTheme.colors.text) }) else null,
            onClick = {},
        )
    }

    @Composable
    private fun StockTargetMenu() {
        DropdownMenu(expanded = true, onDismissRequest = {}) {
            Heading("Machine")
            StockOption("Studio", true)
            StockOption("Old Mac", false)
            HorizontalDivider()
            Heading("Projects")
            StockOption("happy", true)
            StockOption("skills", false)
            DropdownMenuItem(text = { Text("Enter a custom path") }, onClick = {})
            HorizontalDivider()
            Heading("Harness")
            StockOption("Claude Code", true)
            StockOption("Codex", false)
            HorizontalDivider()
            DropdownMenuItem(text = { Text("New bot") }, onClick = {})
        }
    }

    @Composable
    private fun HappyTargetMenu() {
        HappyDropdownMenu(expanded = true, onDismissRequest = {}) {
            HappyMenuSection("Machine")
            HappyMenuItem("Studio", {}, selected = true)
            HappyMenuItem("Old Mac", {})
            HappyMenuDivider()
            HappyMenuSection("Projects")
            HappyMenuItem("happy", {}, selected = true)
            HappyMenuItem("skills", {})
            HappyMenuItem("Enter a custom path", {})
            HappyMenuDivider()
            HappyMenuSection("Harness")
            HappyMenuItem("Claude Code", {}, selected = true)
            HappyMenuItem("Codex", {})
            HappyMenuDivider()
            HappyMenuItem("New bot", {})
        }
    }

    private val accounts = AccountMenu(listOf(
        AccountMenuEntry("0123456789abcdef", "Steve"),
        AccountMenuEntry("agent-connection-1", "Studio", agent = true, active = true),
        AccountMenuEntry("agent-connection-2", "Old Mac", agent = true, attention = true),
    ))

    private fun account(dark: Boolean) {
        show(dark) { AccountMenuButton(accounts, {}, {}) }
        rule.node(AccountMenuTags.BUTTON).performClick()
        save("menu-account-" + if (dark) "dark" else "light")
    }

    @Test fun stockTargetLight() { show(false) { StockTargetMenu() }; save("menu-target-stock-light") }
    @Test fun stockTargetDark() { show(true) { StockTargetMenu() }; save("menu-target-stock-dark") }
    @Test fun happyTargetLight() { show(false) { HappyTargetMenu() }; save("menu-target-happy-light") }
    @Test fun happyTargetDark() { show(true) { HappyTargetMenu() }; save("menu-target-happy-dark") }
    @Test fun accountLight() = account(false)
    @Test fun accountDark() = account(true)
}
