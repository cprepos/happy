package com.slopus.happy.ui.layout

import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * How wide content may grow answers to the window's Material width class,
 * not the device class. The old rule asked whether the diagonal reached 9
 * inches, so a 900x731dp window (wide enough for the tablet shell) was
 * called a phone and ran edge to edge; and before the classes, an unfolded
 * foldable (750) ran edge to edge too.
 */
class ContentWidthTest {
    @Test
    fun widthClassesAreMaterials() {
        assertEquals(WidthClass.Compact, WidthClass.of(411.dp))
        assertEquals(WidthClass.Compact, WidthClass.of(599.dp))
        assertEquals(WidthClass.Medium, WidthClass.of(600.dp))
        assertEquals(WidthClass.Medium, WidthClass.of(750.dp))
        assertEquals(WidthClass.Medium, WidthClass.of(839.dp))
        assertEquals(WidthClass.Expanded, WidthClass.of(840.dp))
        assertEquals(WidthClass.Expanded, WidthClass.of(1280.dp))
    }

    @Test
    fun theTokensPerClass() {
        assertEquals(16.dp, ContentTokens.inset)
        assertEquals(ContentTokens(16.dp, Dp.Infinity), ContentTokens.Compact)
        assertEquals(ContentTokens(24.dp, 640.dp), ContentTokens.Medium)
        assertEquals(ContentTokens(24.dp, 768.dp), ContentTokens.Expanded)
        assertEquals(0.dp, ContentTokens.Compact.gutter)
        assertEquals(8.dp, ContentTokens.Medium.gutter)
        assertEquals(672.dp, ContentTokens.Medium.columnMaxWidth)
        assertEquals(800.dp, ContentTokens.Expanded.columnMaxWidth)
    }

    @Test
    fun keylines() {
        // A phone: its own width, 16 in, as it always was; on its side too.
        assertEquals(16.dp, ContentTokens.Compact.keyline(411.dp))
        assertEquals(16.dp, ContentTokens.Compact.keyline(599.dp))
        // Medium: the 24 margin until the 640 measure binds, then centred.
        assertEquals(24.dp, ContentTokens.Medium.keyline(600.dp))
        assertEquals(24.dp, ContentTokens.Medium.keyline(688.dp))
        assertEquals(55.dp, ContentTokens.Medium.keyline(750.dp))
        // Expanded: the 800 column centred.
        assertEquals(36.dp, ContentTokens.Expanded.keyline(840.dp))
        assertEquals(66.dp, ContentTokens.Expanded.keyline(900.dp))
        assertEquals(256.dp, ContentTokens.Expanded.keyline(1280.dp))
    }

    @Test
    fun theWindowLayoutCarriesTheSameAnswer() {
        val phone = WindowLayout.of(411.dp, 731.dp)
        assertEquals(WidthClass.Compact, phone.widthClass)
        assertEquals(Dp.Infinity, phone.contentMaxWidth)
        assertEquals(phone.contentMaxWidth, phone.headerMaxWidth)
        assertEquals(false, phone.isTablet)

        // A Galaxy Z Fold7's inner screen upright: one pane, a centred readable column.
        val fold = WindowLayout.of(750.dp, 832.dp)
        assertEquals(WidthClass.Medium, fold.widthClass)
        assertEquals(false, fold.isTablet)
        assertEquals(672.dp, fold.contentMaxWidth)

        // On its side too: still medium, still one pane.
        val sideways = WindowLayout.of(832.dp, 750.dp)
        assertEquals(WidthClass.Medium, sideways.widthClass)
        assertEquals(false, sideways.isTablet)
        assertEquals(672.dp, sideways.contentMaxWidth)

        // The shell and the expanded tokens start together.
        val expanded = WindowLayout.of(840.dp, 750.dp)
        assertEquals(WidthClass.Expanded, expanded.widthClass)
        assertEquals(true, expanded.isTablet)

        // Wide enough for the shell, and held in as well.
        val wide = WindowLayout.of(900.dp, 731.dp)
        assertEquals(true, wide.isTablet)
        assertEquals(800.dp, wide.contentMaxWidth)

        val tablet = WindowLayout.of(1280.dp, 800.dp)
        assertEquals(true, tablet.isTablet)
        assertEquals(800.dp, tablet.contentMaxWidth)

        // A phone on its side is medium by width: the 24 margin, the 640 measure.
        val landscape = WindowLayout.of(731.dp, 411.dp)
        assertEquals(WidthClass.Medium, landscape.widthClass)
        assertEquals(true, landscape.isLandscape)
    }
}
