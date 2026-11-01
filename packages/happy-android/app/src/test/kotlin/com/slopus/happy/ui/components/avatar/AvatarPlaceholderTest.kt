package com.slopus.happy.ui.components.avatar

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

/** Which bundled picture an ID wears, and that every one of them ships: happy-ios's AvatarPlaceholderTests, value for value. */
class AvatarPlaceholderTest {
    /**
     * Pinned to happy-ios's own pins (AvatarPlaceholderTests.swift), so an
     * ID wears the same picture on both phones and a change to the hash
     * (which would hand everyone a new picture) fails here.
     */
    @Test
    fun thePickIsPinnedToHappyIos() {
        assertEquals(2_872_998_923L, AvatarPlaceholder.hash("").toLong() and 0xFFFF_FFFFL)
        assertEquals(482_950_588L, AvatarPlaceholder.hash("abc").toLong() and 0xFFFF_FFFFL)
        assertEquals(123, AvatarPlaceholder.index(""))
        assertEquals(188, AvatarPlaceholder.index("abc"))
        assertEquals(180, AvatarPlaceholder.index("account-1"))
        assertEquals(16, AvatarPlaceholder.index("account-2"))
        assertEquals("UTF-8 bytes", 38, AvatarPlaceholder.index("😀x"))
        assertEquals("avatar-placeholder-016", AvatarPlaceholder.name("person:ada@example.com"))
    }

    @Test
    fun theSameSeedAlwaysPicksTheSamePicture() {
        for (seed in listOf("", "a", "account-1", UUID.randomUUID().toString())) {
            assertEquals(AvatarPlaceholder.index(seed), AvatarPlaceholder.index(String(seed.toCharArray())))
        }
    }

    /** 20,000 IDs that differ only at their end land on every picture, none far from its share of 100. */
    @Test
    fun picksSpreadOverEveryPicture() {
        val counts = IntArray(AvatarPlaceholder.COUNT)
        for (index in 0 until 20_000) counts[AvatarPlaceholder.index("seed-$index")]++
        assertEquals("pictures no seed picks", 0, counts.count { it == 0 })
        assertTrue(counts.min() >= 60)
        assertTrue(counts.max() <= 150)
        val neighbours = (0 until 1000).count { AvatarPlaceholder.index("seed-$it") == AvatarPlaceholder.index("seed-${it + 1}") }
        assertTrue("neighbouring IDs share a picture $neighbours times", neighbours < 20)
    }

    @Test
    fun names() {
        assertEquals("avatar-placeholder-001", AvatarPlaceholder.name(0))
        assertEquals("avatar-placeholder-200", AvatarPlaceholder.name(199))
        assertEquals("avatar-placeholders/avatar-placeholder-007.webp", AvatarPlaceholder.asset(6))
    }

    /**
     * Every picture a seed can pick ships in the assets as a WebP, byte for
     * byte happy-ios's, nothing else is there, and the shaders' MIT notice
     * goes with them. Run `node tools/avatars/generate.mjs` when this fails.
     */
    @Test
    fun everyPictureIsBundledAsHappyIosHasIt() {
        val assets = File("src/main/assets/${AvatarPlaceholder.ASSET_DIR}")
        val ios = File("../../happy-ios/Sources/HappyUI/Resources/AvatarPlaceholders")
        var total = 0L
        for (index in 0 until AvatarPlaceholder.COUNT) {
            val name = "${AvatarPlaceholder.name(index)}.webp"
            val bytes = File(assets, name).readBytes()
            assertEquals(name, "RIFF", String(bytes, 0, 4))
            assertEquals(name, "WEBP", String(bytes, 8, 4))
            if (ios.isDirectory) assertArrayEquals(name, File(ios, name).readBytes(), bytes)
            total += bytes.size
        }
        val pictures = assets.list()!!.filter { it.endsWith(".webp") }.toSet()
        assertEquals((0 until AvatarPlaceholder.COUNT).map { "${AvatarPlaceholder.name(it)}.webp" }.toSet(), pictures)
        assertTrue("the pictures take $total bytes", total < 3_000_000)
        val license = File(assets, "LICENSE-craftedstudios-shaders.txt").readText()
        assertTrue(license.contains("MIT License"))
        assertTrue(license.contains("Copyright (c) 2026 Crafted Studios"))
        assertTrue(File(assets, "AVATAR-PLACEHOLDERS-NOTICE.md").isFile)
    }
}
