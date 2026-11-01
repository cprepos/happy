package com.slopus.happy.text

import android.content.res.Resources
import androidx.annotation.StringRes
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.platform.LocalResources

/**
 * Words for the person, decided away from the UI: someone else's (a
 * machine's, git's, the server's), shown as they are, or the app's own, a
 * string resource the UI puts in the person's language. Code outside
 * composition returns these instead of English sentences.
 */
@Immutable
sealed interface Words {
    /** Words the app didn't write, shown as they are. */
    data class Said(val text: String) : Words

    /** The app's own words: [id] with [args] as its format arguments. */
    data class Ours(@StringRes val id: Int, val args: List<Any> = emptyList()) : Words

    companion object {
        fun ours(@StringRes id: Int, vararg args: Any): Words = Ours(id, args.toList())

        /** [text] when there is some, else the app's own [fallback]. */
        fun said(text: String?, @StringRes fallback: Int): Words = text?.takeIf { it.isNotBlank() }?.let(::Said) ?: Ours(fallback)
    }
}

fun Resources.words(words: Words): String = when (words) {
    is Words.Said -> words.text
    is Words.Ours -> getString(words.id, *words.args.toTypedArray())
}

@Composable
@ReadOnlyComposable
fun wordsResource(words: Words): String = LocalResources.current.words(words)
