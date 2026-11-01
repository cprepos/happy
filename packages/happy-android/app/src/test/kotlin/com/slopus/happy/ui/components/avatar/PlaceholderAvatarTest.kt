package com.slopus.happy.ui.components.avatar

import android.provider.Settings
import androidx.compose.foundation.layout.Column
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithTag
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.slopus.happy.ui.PHONE
import com.slopus.happy.ui.assertBox
import com.slopus.happy.ui.bounds
import com.slopus.happy.ui.node
import com.slopus.happy.ui.setHappyContent
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.shadows.ShadowLooper
import java.util.concurrent.TimeUnit

/**
 * When a placeholder moves and when it holds still (happy-ios's
 * HostedLiveAvatarTests): only with Animated Avatars on, only where it may
 * move, only while its screen is resumed and motion is allowed, at most 32
 * at once, and the clock stops when none is left.
 */
@RunWith(AndroidJUnit4::class)
@Config(qualifiers = PHONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class PlaceholderAvatarTest {
    @get:Rule val rule = createComposeRule()

    private val stills get() = rule.onAllNodesWithTag(PlaceholderAvatarTags.STILL, useUnmergedTree = true)
    private val lives get() = rule.onAllNodesWithTag(PlaceholderAvatarTags.LIVE, useUnmergedTree = true)

    @After
    fun motionBack() {
        Settings.Global.putFloat(ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 1f)
    }

    @Test
    fun stillUnlessAnimatedAvatarsIsOn() {
        rule.setHappyContent { PlaceholderAvatar("t1", 30.dp) }
        assertBox("placeholder", rule.node(PlaceholderAvatarTags.STILL).bounds, 0.dp, 0.dp, 30.dp, 30.dp)
        lives.assertCountEquals(0)
        assertFalse(LiveAvatarClock.isTicking)
    }

    /** The still picture is the seed's, decoded at the size it is drawn. */
    @Test
    fun theStillPictureIsDecodedAtItsSize() {
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val image = AvatarPlaceholderImages.decode(context, AvatarPlaceholder.index("t1"), 90)
        assertNotNull(image)
        assertEquals(90, image!!.width)
        assertEquals(90, image.height)
    }

    @Test
    fun movesWhileShownAndTheClockStopsWhenItGoes() {
        assumeTrue("AGSL builds here", AvatarShaderProgram.available)
        var shown by mutableStateOf(true)
        rule.setHappyContent {
            CompositionLocalProvider(LocalAnimatedAvatars provides true) { if (shown) PlaceholderAvatar("t1", 30.dp) }
        }
        lives.assertCountEquals(1)
        assertTrue(LiveAvatarClock.isTicking)
        shown = false
        rule.waitForIdle()
        assertTrue(LiveAvatarClock.live.value.isEmpty())
        ShadowLooper.idleMainLooper(200, TimeUnit.MILLISECONDS)
        assertFalse(LiveAvatarClock.isTicking)
    }

    @Test
    fun aCallerCanKeepItStill() {
        rule.setHappyContent {
            CompositionLocalProvider(LocalAnimatedAvatars provides true) { PlaceholderAvatar("t1", 30.dp, animated = false) }
        }
        stills.assertCountEquals(1)
        lives.assertCountEquals(0)
    }

    @Test
    fun stillWithAnimationsRemoved() {
        Settings.Global.putFloat(ApplicationProvider.getApplicationContext<android.content.Context>().contentResolver, Settings.Global.ANIMATOR_DURATION_SCALE, 0f)
        rule.setHappyContent {
            CompositionLocalProvider(LocalAnimatedAvatars provides true) { PlaceholderAvatar("t1", 30.dp) }
        }
        lives.assertCountEquals(0)
        stills.assertCountEquals(1)
    }

    @Test
    fun stillWhileItsScreenIsNotResumed() {
        assumeTrue("AGSL builds here", AvatarShaderProgram.available)
        val owner = object : LifecycleOwner {
            val registry = LifecycleRegistry.createUnsafe(this).apply { currentState = Lifecycle.State.STARTED }
            override val lifecycle: Lifecycle get() = registry
        }
        rule.setHappyContent {
            CompositionLocalProvider(LocalAnimatedAvatars provides true, LocalLifecycleOwner provides owner) { PlaceholderAvatar("t1", 30.dp) }
        }
        lives.assertCountEquals(0)
        assertTrue(LiveAvatarClock.live.value.isEmpty())
        rule.runOnIdle { owner.registry.currentState = Lifecycle.State.RESUMED }
        rule.waitForIdle()
        lives.assertCountEquals(1)
        rule.runOnIdle { owner.registry.currentState = Lifecycle.State.STARTED }
        rule.waitForIdle()
        lives.assertCountEquals(0)
    }

    @Test
    fun atMost32MoveAtOnce() {
        assumeTrue("AGSL builds here", AvatarShaderProgram.available)
        rule.setHappyContent {
            CompositionLocalProvider(LocalAnimatedAvatars provides true) {
                Column { repeat(40) { PlaceholderAvatar("seed-$it", 10.dp) } }
            }
        }
        lives.assertCountEquals(LiveAvatarClock.MAX_LIVE)
        stills.assertCountEquals(40 - LiveAvatarClock.MAX_LIVE)
    }
}
