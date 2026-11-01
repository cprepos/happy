package com.slopus.happy.text

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * The strings happy-app's catalogs don't have (res/values/strings_<area>.xml)
 * are in every language the generated strings.xml is: each one in
 * values-<locale>/ under the same file name, with the same placeholders, and
 * each plural with the categories Android uses for that language. Nothing is
 * left in a locale that English no longer has.
 *
 * Exempt: strings.xml, generated from happy-app's catalogs
 * (TranslationResourcesTest checks it). Every strings_<area>.xml is
 * translated, happy-app's inline English included (AGENTS.md, Localization).
 */
class AndroidStringsTranslatedTest {
    private val res = File("src/main/res")

    private val locales = res.listFiles { dir -> dir.isDirectory && dir.name.startsWith("values-") && File(dir, "strings.xml").exists() }!!
        .map { it.name }
        .sorted()

    private val sources = res.resolve("values").listFiles { file -> file.name.startsWith("strings_") }!!
        .sortedBy { it.name }

    private class Entry(val placeholders: Set<String>, val quantities: Set<String>?)

    private fun read(file: File): Map<String, Entry> {
        val document = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file)
        val out = LinkedHashMap<String, Entry>()
        val nodes = document.documentElement.childNodes
        for (index in 0 until nodes.length) {
            val node = nodes.item(index) as? Element ?: continue
            if (node.getAttribute("translatable") == "false") continue
            val name = node.getAttribute("name")
            out[name] = when (node.tagName) {
                "string" -> Entry(placeholders(node.textContent), null)
                "plurals" -> {
                    val items = node.getElementsByTagName("item")
                    val texts = (0 until items.length).map { items.item(it) as Element }
                    Entry(texts.flatMap { placeholders(it.textContent) }.toSet(), texts.map { it.getAttribute("quantity") }.toSet())
                }
                else -> continue
            }
        }
        return out
    }

    private fun placeholders(text: String): Set<String> = Regex("%(\\d+\\$)?[sd]").findAll(text).map { it.value }.toSet()

    @Test
    fun theLanguagesAreTheCatalogs() {
        assertEquals(listOf("values-b+zh+Hans", "values-b+zh+Hant", "values-ca", "values-es", "values-it", "values-ja", "values-pl", "values-pt", "values-ru"), locales)
        assertTrue(sources.size >= 13)
    }

    @Test
    fun everyStringIsInEveryLanguage() {
        val problems = ArrayList<String>()
        for (source in sources) {
            val english = read(source)
            for (locale in locales) {
                val file = res.resolve("$locale/${source.name}")
                val translated = if (file.exists()) read(file) else emptyMap()
                for ((name, entry) in english) {
                    val other = translated[name]
                    when {
                        other == null -> problems += "$locale/${source.name}: $name is missing"
                        other.placeholders != entry.placeholders -> problems += "$locale/${source.name}: $name has ${other.placeholders}, English ${entry.placeholders}"
                        entry.quantities != null && other.quantities != QUANTITIES.getValue(locale) ->
                            problems += "$locale/${source.name}: $name has ${other.quantities}, $locale needs ${QUANTITIES.getValue(locale)}"
                    }
                }
                for (name in translated.keys - english.keys) problems += "$locale/${source.name}: $name is no longer in English"
            }
        }
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
    }

    @Test
    fun noLocaleHasAFileEnglishHasNot() {
        val names = sources.map { it.name }.toSet()
        for (locale in locales) {
            val extra = res.resolve(locale).list()!!.filter { it.startsWith("strings_") && it !in names }
            assertTrue("$locale: $extra", extra.isEmpty())
        }
    }

    private companion object {
        /** Android's plural categories per language, as generate.mjs writes them. */
        val QUANTITIES = mapOf(
            "values-ru" to setOf("one", "few", "many", "other"),
            "values-pl" to setOf("one", "few", "many", "other"),
            "values-es" to setOf("one", "many", "other"),
            "values-it" to setOf("one", "many", "other"),
            "values-pt" to setOf("one", "many", "other"),
            "values-ca" to setOf("one", "many", "other"),
            "values-ja" to setOf("other"),
            "values-b+zh+Hans" to setOf("other"),
            "values-b+zh+Hant" to setOf("other"),
        )
    }
}
