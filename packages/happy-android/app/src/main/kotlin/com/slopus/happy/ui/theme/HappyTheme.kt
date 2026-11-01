package com.slopus.happy.ui.theme

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.LocalTextSelectionColors
import androidx.compose.foundation.text.selection.TextSelectionColors
import androidx.compose.material3.ColorScheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Typography
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.slopus.happy.ui.components.ProvideShimmerClock

/** Spacing, radius and icon scales shared by both themes (theme.ts `sharedSpacing`). */
@Immutable
object HappySpacing {
    val xs: Dp = 4.dp
    val sm: Dp = 8.dp
    val md: Dp = 12.dp
    val lg: Dp = 16.dp
    val xl: Dp = 20.dp
    val xxl: Dp = 24.dp
}

@Immutable
object HappyRadius {
    val sm: Dp = 4.dp
    val md: Dp = 8.dp
    val lg: Dp = 10.dp
    val xl: Dp = 12.dp
    val xxl: Dp = 16.dp
}

@Immutable
object HappyIconSize {
    val small: Dp = 12.dp
    val medium: Dp = 16.dp
    val large: Dp = 20.dp
    val xlarge: Dp = 24.dp
}

/** localSettings.themePreference */
enum class ThemePreference { Adaptive, Light, Dark }

private val LocalHappyColors = staticCompositionLocalOf { LightColors }

object HappyTheme {
    val colors: HappyColors
        @Composable @ReadOnlyComposable get() = LocalHappyColors.current
}

/**
 * Happy's tokens are the source of truth; the Material 3 scheme is derived
 * from them only so stock Material components (dialogs, text fields) do not
 * pull in Material's default purple.
 */
@Composable
fun HappyTheme(
    preference: ThemePreference = ThemePreference.Adaptive,
    content: @Composable () -> Unit,
) {
    val dark = when (preference) {
        ThemePreference.Adaptive -> isSystemInDarkTheme()
        ThemePreference.Light -> false
        ThemePreference.Dark -> true
    }
    val colors = if (dark) DarkColors else LightColors
    val scheme = happyColorScheme(colors)
    CompositionLocalProvider(LocalHappyColors provides colors) {
        // One clock for every shimmer under the theme: a screen of working rows is one frame loop.
        ProvideShimmerClock {
            MaterialTheme(colorScheme = scheme, shapes = HappyShapes, typography = HappyMaterialType) {
                // Selection handles and highlight in the link blue, as iOS's tint, not Material's primary.
                CompositionLocalProvider(
                    LocalTextSelectionColors provides TextSelectionColors(colors.textLink, colors.textLink.copy(alpha = 0.3f)),
                    content = content,
                )
            }
        }
    }
}

/**
 * Every Material role as one of Happy's neutrals, so stock components (a
 * plain DropdownMenu, a FAB, a dialog, a sheet, a switch, a snackbar) never
 * pick up Material's default lavender or its purple-grey tonal surfaces, and
 * tonal elevation tints nothing. No dynamic colour. A plain DropdownMenu's
 * container ([ColorScheme.surfaceContainer]) is the one [HappyDropdownMenu]
 * uses: white in light, the lifted grey in dark.
 */
private fun happyColorScheme(colors: HappyColors): ColorScheme {
    val base = if (colors.dark) darkColorScheme() else lightColorScheme()
    val onAccent = if (colors.dark) Color.Black else Color.White
    return base.copy(
        primary = colors.text,
        onPrimary = colors.grouped.background,
        primaryContainer = colors.surfaceHighest,
        onPrimaryContainer = colors.text,
        inversePrimary = colors.textLink,
        secondary = colors.textSecondary,
        onSecondary = colors.surface,
        secondaryContainer = colors.surfaceSelected,
        onSecondaryContainer = colors.text,
        tertiary = colors.textLink,
        onTertiary = onAccent,
        tertiaryContainer = colors.surfaceHighest,
        onTertiaryContainer = colors.text,
        background = colors.grouped.background,
        onBackground = colors.text,
        surface = colors.surface,
        onSurface = colors.text,
        surfaceVariant = colors.surfaceHigh,
        onSurfaceVariant = colors.textSecondary,
        surfaceTint = colors.surface,
        inverseSurface = colors.text,
        inverseOnSurface = colors.surface,
        error = colors.textDestructive,
        onError = Color.White,
        errorContainer = colors.boxError.background,
        onErrorContainer = colors.boxError.text,
        outline = colors.textSecondary,
        // Translucent, so a stock divider shows on any of the neutrals, a menu's lifted grey included.
        outlineVariant = colors.text.copy(alpha = if (colors.dark) 0.14f else 0.1f),
        scrim = Color.Black,
        surfaceBright = colors.surface,
        surfaceDim = colors.surfaceHigh,
        surfaceContainerLowest = colors.grouped.background,
        surfaceContainerLow = colors.surface,
        surfaceContainer = if (colors.dark) colors.surfaceHighest else colors.surface,
        surfaceContainerHigh = colors.surfaceHigh,
        surfaceContainerHighest = colors.surfaceHighest,
    )
}

/**
 * Material's extra-small shape is a stock menu's (and a plain tooltip's): 16
 * round, as [HappyDropdownMenu]'s and iOS's context menus, not Material's 4.
 */
private val HappyShapes = Shapes(extraSmall = RoundedCornerShape(16.dp))

/**
 * Material's type, but a stock menu row's and text button's label
 * (label large) in the regular weight: Material's medium reads heavy in the
 * system font, and iOS's menus and buttons are regular. Sizes are Material's.
 */
private val HappyMaterialType = Typography().let { base ->
    base.copy(labelLarge = base.labelLarge.copy(fontWeight = FontWeight.Normal))
}
