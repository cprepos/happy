package com.slopus.happy.config

import android.content.SharedPreferences
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Settings › Appearance › Animated Avatars (happy-ios's `LiveAvatars`,
 * UserDefaults `live-avatars`): placeholders move as their shaders. Kept on
 * this phone for every account, so a logout doesn't reset it; off unless
 * turned on. happy-app has no equivalent.
 */
class LiveAvatarsSetting(private val prefs: SharedPreferences) {
    private val state = MutableStateFlow(prefs.getBoolean(KEY, false))

    val enabled: StateFlow<Boolean> = state.asStateFlow()

    fun set(on: Boolean) {
        if (on == state.value) return
        prefs.edit().putBoolean(KEY, on).apply()
        state.value = on
    }

    companion object {
        const val PREFS_NAME = "avatars"
        private const val KEY = "live-avatars"
    }
}
