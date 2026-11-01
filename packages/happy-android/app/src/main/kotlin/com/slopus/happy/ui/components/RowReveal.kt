package com.slopus.happy.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.gestures.animateScrollBy
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.composed
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.Dp
import com.slopus.happy.ui.theme.HappyTheme
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The row a page was opened to show (Settings' search found it there), as
 * iOS's `SettingsPageViewController.reveal`: once the page is laid out, its
 * [ItemList] scrolls the row to the middle of what shows under the bar, as
 * near as the content allows, and the row flashes once (pressed colour,
 * held 0.6 s, gone over 0.8 s). Nothing runs on its own. Once only: back
 * on the page later, or after a recreation, it stays where it is.
 */
@Stable
class RowReveal internal constructor(val id: String, done: MutableState<Boolean>) {
    var done by done
        internal set
}

val LocalRowReveal = staticCompositionLocalOf<RowReveal?> { null }

/** Shows the row [id] (a [revealRow] on this page), if there is one, once. */
@Composable
fun ProvideRowReveal(id: String?, content: @Composable () -> Unit) {
    if (id == null) return content()
    val done = rememberSaveable(id) { mutableStateOf(false) }
    val reveal = remember(id) { RowReveal(id, done) }
    CompositionLocalProvider(LocalRowReveal provides reveal, content = content)
}

/** What an [ItemList] gives its rows to scroll one into view: its scroll, its frame and the bar's room over it. */
internal class RevealScroller(private val scroll: ScrollState, private val barTop: Dp) {
    var viewport: LayoutCoordinates? = null

    /** Scrolls [row]'s middle to the middle of what shows between the bar and the bottom. */
    suspend fun center(row: LayoutCoordinates, density: androidx.compose.ui.unit.Density) {
        val view = viewport?.takeIf { it.isAttached && row.isAttached } ?: return
        val box = view.localBoundingBoxOf(row, clipBounds = false)
        val top = with(density) { barTop.toPx() }
        val shown = view.size.height - top
        scroll.animateScrollBy(box.center.y - (top + shown / 2))
    }
}

internal val LocalRevealScroller = staticCompositionLocalOf<RevealScroller?> { null }

/**
 * Tags a settings row [id] (its test tag too) and, when it is the row the
 * page was opened to show ([ProvideRowReveal]), scrolls to it and flashes it.
 */
fun Modifier.revealRow(id: String): Modifier = testTag(id).composed {
    val reveal = LocalRowReveal.current?.takeIf { it.id == id } ?: return@composed Modifier
    val scroller = LocalRevealScroller.current
    val density = LocalDensity.current
    val scope = rememberCoroutineScope()
    val flash = remember { Animatable(0f) }
    val color = HappyTheme.colors.surfacePressed
    Modifier
        .onGloballyPositioned { row ->
            if (reveal.done) return@onGloballyPositioned
            reveal.done = true
            scope.launch {
                // After this frame, when the list knows its frame and how far it scrolls.
                withFrameNanos { }
                scroller?.center(row, density)
            }
            scope.launch {
                flash.snapTo(1f)
                delay(600)
                flash.animateTo(0f, tween(800, easing = LinearOutSlowInEasing))
            }
        }
        .drawBehind { if (flash.value > 0f) drawRect(color.copy(alpha = color.alpha * flash.value)) }
}
