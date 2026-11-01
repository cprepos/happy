package com.slopus.happy.conversation

import kotlin.math.abs
import kotlin.math.min

/**
 * Dragging a whole picture up or down to put the viewer away, as iOS's
 * `PictureDismissal` (HappyLayout/Agents/ChatViewingLayout.swift): the
 * picture follows the finger, shrinking to 0.8 as the black fades out over
 * half the screen's height; let go past 100 dp, or flung faster than 800
 * dp/s, it closes, unless flung back toward the middle.
 */
data class PictureDismissal(val progress: Float, val groundAlpha: Float, val scale: Float, val closes: Boolean) {
    companion object {
        /** How far, as a share of the screen's height, takes the ground away. */
        const val FADE_DISTANCE = 0.5f
        /** The size it shrinks to at most. */
        const val MIN_SCALE = 0.8f
        const val CLOSING_DISTANCE = 100f
        const val CLOSING_SPEED = 800f

        /** [translation] and [velocity] are the finger's along the screen's height, in dp and dp/s. */
        fun of(translation: Float, velocity: Float, height: Float): PictureDismissal {
            val progress = if (height > 0) min(1f, abs(translation) / (height * FADE_DISTANCE)) else 0f
            // Flung back toward the middle, it stays, however far it was.
            val flungBack = translation != 0f && velocity != 0f && (translation > 0) != (velocity > 0) && abs(velocity) > CLOSING_SPEED
            val closes = !flungBack && (abs(translation) > CLOSING_DISTANCE || (abs(velocity) > CLOSING_SPEED && abs(translation) > 10))
            return PictureDismissal(progress, 1 - progress, 1 - (1 - MIN_SCALE) * progress, closes)
        }
    }
}
