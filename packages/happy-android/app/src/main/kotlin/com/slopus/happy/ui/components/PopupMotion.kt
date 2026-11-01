package com.slopus.happy.ui.components

import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.MutableTransitionState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.rememberTransition
import androidx.compose.animation.core.snap
import androidx.compose.animation.core.tween
import androidx.annotation.StyleRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.util.lerp
import androidx.compose.ui.window.DialogWindowProvider
import com.slopus.happy.R

/**
 * How everything that pops over a screen comes and goes, one motion for all
 * (Material 3's menu motion): a menu or anchored popup scales up from 0.85
 * out of the corner nearest its anchor while it fades in over the first half,
 * 200 ms on the emphasized-decelerate curve, and goes back the same way in
 * 140 ms, accelerating. A dialog does the same from its centre, from 0.92.
 * Sheets slide ([SheetMotion]). With animations off, all of it is instant.
 */
object PopupMotion {
    const val ENTER_MS = 200
    const val EXIT_MS = 140
    const val MENU_SCALE = 0.85f
    const val DIALOG_SCALE = 0.92f
    val enterEasing = CubicBezierEasing(0.05f, 0.7f, 0.1f, 1f)
    val exitEasing = CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)
}

/** A sheet from the bottom: up in 300 ms decelerating, down in 200 ms accelerating. */
object SheetMotion {
    const val ENTER_MS = 300
    const val EXIT_MS = 200
}

/**
 * How a dialog's window comes and goes (res/values/motion.xml), the same
 * curves as [PopupMotion] and [SheetMotion]: the platform runs them, exit
 * included, and drops them when animations are off.
 */
enum class WindowMotion(@StyleRes val style: Int) {
    /** A centred card: [PopupMotion]'s dialog scale and fade. */
    Dialog(R.style.HappyDialogAnimation),

    /** Over the whole window from the bottom: [SheetMotion]. */
    Sheet(R.style.HappySheetAnimation),

    /** A full-window viewer: a plain fade. */
    Fade(R.style.HappyFadeAnimation),
}

/**
 * Gives the dialog this is composed in [motion]. Call it first thing inside
 * a [androidx.compose.ui.window.Dialog]'s content; the window takes it
 * before it is first drawn.
 */
@Composable
fun DialogWindowMotion(motion: WindowMotion = WindowMotion.Dialog) {
    val view = LocalView.current
    DisposableEffect(view, motion) {
        (view.parent as? DialogWindowProvider)?.window?.setWindowAnimations(motion.style)
        onDispose {}
    }
}

/**
 * 0 to 1 as [state] goes from hidden to shown, on [PopupMotion]'s curves
 * (instant with animations off). Read it in [popupMotion].
 */
@Composable
fun rememberPopupProgress(state: MutableTransitionState<Boolean>, enterMs: Int = PopupMotion.ENTER_MS, exitMs: Int = PopupMotion.EXIT_MS): State<Float> {
    val instant = rememberReduceMotion()
    val transition = rememberTransition(state, label = "popup")
    return transition.animateFloat(
        transitionSpec = {
            when {
                instant -> snap()
                targetState -> tween(enterMs, easing = PopupMotion.enterEasing)
                else -> tween(exitMs, easing = PopupMotion.exitEasing)
            }
        },
        label = "popupProgress",
    ) { if (it) 1f else 0f }
}

/** Scales from [fromScale] about [origin] and fades in over the first half of [progress]. */
fun Modifier.popupMotion(progress: () -> Float, origin: () -> TransformOrigin = { TransformOrigin.Center }, fromScale: Float = PopupMotion.MENU_SCALE): Modifier =
    graphicsLayer {
        val p = progress()
        val scale = lerp(fromScale, 1f, p)
        scaleX = scale
        scaleY = scale
        alpha = (p * 2f).coerceIn(0f, 1f)
        transformOrigin = origin()
    }

/**
 * Whether something [shown] is still on screen, kept for its exit: true
 * from the moment it shows until it has finished going.
 */
@Composable
fun rememberPopupState(shown: Boolean): MutableTransitionState<Boolean> {
    val state = remember { MutableTransitionState(false) }
    state.targetState = shown
    return state
}

val MutableTransitionState<Boolean>.onScreen: Boolean get() = currentState || targetState

/** The last non-null [value], so what was open can draw itself while it closes. */
@Composable
fun <T : Any> rememberLastShown(value: T?): T? {
    // Not state: it only remembers what composition already saw.
    val last = remember { LastShown<T>() }
    if (value != null) last.value = value
    return value ?: last.value
}

private class LastShown<T : Any> {
    var value: T? = null
}
