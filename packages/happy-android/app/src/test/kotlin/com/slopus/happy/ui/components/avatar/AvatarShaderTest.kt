package com.slopus.happy.ui.components.avatar

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.PI
import kotlin.math.abs

/**
 * What the live shader draws each placeholder with: one entry per picture,
 * in the pictures' order, the same numbers as happy-ios's table
 * (AvatarShaderTests.swift's checks, and the table itself).
 */
class AvatarShaderTest {
    /** The first picture's entry as node gives it from @craftedstudios/shaders 1.0.1 `resolve({ seed: '0b7ttho', effect: 'linear', size: 1024 })`. */
    @Test
    fun theFirstEntryIsThePackages() {
        val first = AvatarShader.parameters(0)
        assertEquals(AvatarShader.Effect.Linear, first.effect)
        assertEquals(12, first.colors.size)
        assertEquals(0.881884f, first.colors[0], 1e-6f)
        assertEquals(0.971817f, first.colors[5], 1e-6f)
        assertEquals(0.777775f, first.colors[10], 1e-6f)
        assertEquals(0.132549f, first.layout[0], 1e-6f)
        assertEquals(0.246399f, first.layout[2], 1e-6f)
        assertEquals(1.06f, first.layout[3], 1e-6f)
        assertEquals(17.1f, first.phase, 1e-5f)
        // renderer.js angleOf: phase × the golden angle, mod 2π.
        assertEquals((17.1 * 2.39996).rem(2 * PI), first.angle.toDouble(), 1e-5)
        val fortieth = AvatarShader.parameters(39)
        assertEquals(0f, fortieth.colors[11])
        assertEquals(43.6f, fortieth.phase, 1e-5f)
    }

    /** Every entry, number for number, is happy-ios's AvatarShaderTable.swift: the same ID moves the same way on both phones. */
    @Test
    fun theTableIsHappyIos() {
        val swift = File("../../happy-ios/Sources/HappyLayout/AvatarShaderTable.swift")
        if (!swift.isFile) return
        val rows = Regex("""\.init\(effect: \.(\w+), colors: \[(.*?)], layout: SIMD4\((.*?)\), angle: (\S+), phase: (\S+)\),""")
            .findAll(swift.readText()).toList()
        assertEquals(AvatarPlaceholder.COUNT, rows.size)
        rows.forEachIndexed { index, match ->
            val (effect, colors, layout, angle, phase) = match.destructured
            val entry = AvatarShader.parameters(index)
            assertEquals("$index", effect, entry.effect.name.replaceFirstChar(Char::lowercase))
            val rgb = Regex("""SIMD3\((.*?)\)""").findAll(colors).flatMap { it.groupValues[1].split(", ") }.map(String::toFloat).toList()
            assertEquals("$index colours", rgb, entry.colors.toList())
            assertEquals("$index layout", layout.split(", ").map(String::toFloat), entry.layout.toList())
            assertEquals("$index angle", angle.toFloat(), entry.angle)
            assertEquals("$index phase", phase.toFloat(), entry.phase)
        }
    }

    /** One entry per picture, with the effect the notice says it was made with: the wall's five chapters of 40. */
    @Test
    fun everyPictureHasItsEffect() {
        val notice = File("src/main/assets/${AvatarPlaceholder.ASSET_DIR}/AVATAR-PLACEHOLDERS-NOTICE.md").readLines()
        val effects = notice.filter { it.startsWith("| `avatar-placeholder-") }.map { it.split("|").filter(String::isNotBlank).last().trim() }
        assertEquals(AvatarPlaceholder.COUNT, effects.size)
        effects.forEachIndexed { index, effect ->
            assertEquals("placeholder ${index + 1}", effect, AvatarShader.parameters(index).effect.name.lowercase())
        }
        assertEquals(AvatarShader.Effect.entries.toSet(), (0 until AvatarPlaceholder.COUNT).map { AvatarShader.parameters(it).effect }.toSet())
    }

    /** Everything in range: colours in 0...1, the zoom 0.85...1.2, the offset a fifth each way, the phase under 100 seconds. */
    @Test
    fun everyEntryIsInRange() {
        for (index in 0 until AvatarPlaceholder.COUNT) {
            val entry = AvatarShader.parameters(index)
            assertTrue("$index", entry.colors.all { it in 0f..1f })
            assertTrue("$index", entry.layout[3] in 0.85f..1.2f)
            assertTrue("$index", abs(entry.layout[0]) <= 0.2f && abs(entry.layout[1]) <= 0.2f)
            assertTrue("$index", entry.layout[2] in 0f..(2 * PI.toFloat()))
            assertTrue("$index", entry.phase >= 0f && entry.phase < 100f)
        }
    }

    /** A seed's live placeholder is its still picture's, and its clock starts at that picture's frame. */
    @Test
    fun aSeedMovesFromItsPicturesFrame() {
        for (seed in listOf("", "abc", "person:ada@example.com", "agent:studio.local")) {
            val parameters = AvatarShader.parameters(seed)
            assertTrue(parameters === AvatarShader.parameters(AvatarPlaceholder.index(seed)))
            assertEquals(parameters.phase, AvatarShader.time(parameters, 0.0))
            assertEquals(parameters.phase + 2.5f, AvatarShader.time(parameters, 2.5), 1e-5f)
        }
    }

    @Test
    fun theGrainGrowsWithTheAvatar() {
        assertEquals(1f, AvatarShader.grainCell(144))
        assertEquals(2f, AvatarShader.grainCell(1080))
    }
}
