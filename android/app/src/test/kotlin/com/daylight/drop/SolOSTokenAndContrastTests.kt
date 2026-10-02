package com.daylight.drop

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import kotlin.math.pow

/**
 * Unit tests verifying Sol:OS 8-bit monochromatic tokens, WCAG 2.1 AAA contrast matrices,
 * brand accent color collapse protection, and Zero-EPD architectural invariants.
 * Parses production XML resources directly rather than relying on dummy in-memory literals.
 */
class SolOSTokenAndContrastTests {

    companion object {
        fun parseHexColor(hex: String): Triple<Int, Int, Int> {
            val clean = hex.removePrefix("#")
            // Handle 8-digit ARGB hex if present
            val rgbClean = if (clean.length == 8) clean.substring(2) else clean
            val r = rgbClean.substring(0, 2).toInt(16)
            val g = rgbClean.substring(2, 4).toInt(16)
            val b = rgbClean.substring(4, 6).toInt(16)
            return Triple(r, g, b)
        }

        fun relativeLuminance(r: Int, g: Int, b: Int): Double {
            fun channelLum(c: Int): Double {
                val s = c / 255.0
                return if (s <= 0.04045) s / 12.92 else ((s + 0.055) / 1.055).pow(2.4)
            }
            return 0.2126 * channelLum(r) + 0.7152 * channelLum(g) + 0.0722 * channelLum(b)
        }

        fun contrastRatio(hex1: String, hex2: String): Double {
            val (r1, g1, b1) = parseHexColor(hex1)
            val (r2, g2, b2) = parseHexColor(hex2)
            val l1 = relativeLuminance(r1, g1, b1)
            val l2 = relativeLuminance(r2, g2, b2)
            val lighter = maxOf(l1, l2)
            val darker = minOf(l1, l2)
            return (lighter + 0.05) / (darker + 0.05)
        }

        fun cielabL(hex: String): Double {
            val (r, g, b) = parseHexColor(hex)
            val y = relativeLuminance(r, g, b)
            return if (y > 0.008856) 116.0 * y.pow(1.0 / 3.0) - 16.0 else 903.3 * y
        }
    }

    private fun findFile(relativePath: String): File {
        val candidates = listOf(
            File(relativePath),
            File("android/app", relativePath),
            File("app", relativePath),
            File("../app", relativePath)
        )
        return candidates.firstOrNull { it.exists() }
            ?: throw IllegalStateException("Could not locate file $relativePath in any candidate path")
    }

    private fun loadColorsFromXml(): Map<String, String> {
        val colorsFile = findFile("src/main/res/values/colors.xml")
        val map = mutableMapOf<String, String>()
        val regex = Regex("""<color name="([^"]+)">([^<]+)</color>""")
        for (match in regex.findAll(colorsFile.readText())) {
            val name = match.groupValues[1]
            val hex = match.groupValues[2].trim()
            map[name] = hex
        }
        return map
    }

    @Test
    fun testProductionColorsXmlDefinesAllCanonicalTokens() {
        val colors = loadColorsFromXml()

        assertEquals("#FFFFFF", colors["os_0"])
        assertEquals("#F7F7F7", colors["os_50"])
        assertEquals("#DCD5C9", colors["os_100"])
        assertEquals("#F5F5F5", colors["os_150"])
        assertEquals("#CCCCCC", colors["os_200"])
        assertEquals("#858585", colors["os_300"])
        assertEquals("#535353", colors["os_400"])
        assertEquals("#343434", colors["os_800"])
        assertEquals("#1A1A1A", colors["os_900"])
        assertEquals("#000000", colors["os_1000"])

        assertEquals("#CECECE", colors["os_yellow"])
        assertEquals("#9D9D9E", colors["os_amber"])
        assertEquals("#6C6C6D", colors["os_orange"])
    }

    @Test
    fun testWcagAaaPrimaryTextContrastFromProductionTokens() {
        val colors = loadColorsFromXml()

        // Primary text ink (os_900) on base ground (os_0) must satisfy WCAG AAA (>= 7.0:1)
        val ratio900 = contrastRatio(colors["os_900"]!!, colors["os_0"]!!)
        assertTrue("os_900 on os_0 must be >= 7.0:1, was $ratio900", ratio900 >= 7.0)
        assertTrue("os_900 on os_0 ratio should exceed 17.0:1", ratio900 > 17.0) // ~17.40:1

        // Max black (os_1000) on base ground (os_0) must satisfy WCAG AAA (21.0:1)
        val ratio1000 = contrastRatio(colors["os_1000"]!!, colors["os_0"]!!)
        assertTrue("os_1000 on os_0 must be >= 21.0:1", ratio1000 >= 21.0)
    }

    @Test
    fun testWcagAaaCardSurfaceContrastFromProductionTokens() {
        val colors = loadColorsFromXml()

        // Primary text ink (os_900) on card surface (os_50) must satisfy WCAG AAA (>= 7.0:1)
        val ratio = contrastRatio(colors["os_900"]!!, colors["os_50"]!!)
        assertTrue("os_900 on os_50 must be >= 7.0:1, was $ratio", ratio >= 7.0)
        assertTrue("os_900 on os_50 ratio should exceed 16.0:1", ratio > 16.0) // ~16.25:1
    }

    @Test
    fun testWcagAaaSecondaryTextContrastFromProductionTokens() {
        val colors = loadColorsFromXml()

        // Secondary text ink (os_400) on base canvas (os_0) must satisfy WCAG AAA (>= 7.0:1)
        val ratioCanvas = contrastRatio(colors["os_400"]!!, colors["os_0"]!!)
        assertTrue("os_400 on os_0 must be >= 7.0:1, was $ratioCanvas", ratioCanvas >= 7.0)

        // Inverted button text (os_0 on os_800) must satisfy WCAG AAA (>= 7.0:1)
        val ratioButton = contrastRatio(colors["os_0"]!!, colors["os_800"]!!)
        assertTrue("os_0 on os_800 must be >= 7.0:1, was $ratioButton", ratioButton >= 7.0)
        assertTrue("os_0 on os_800 ratio should exceed 12.0:1", ratioButton > 12.0) // ~12.45:1
    }

    @Test
    fun testTertiaryTextForbiddenForBodyFromProductionTokens() {
        val colors = loadColorsFromXml()

        // Tertiary text (os_300) on base canvas (os_0) fails WCAG AAA (< 7.0:1)
        val ratio = contrastRatio(colors["os_300"]!!, colors["os_0"]!!)
        assertTrue("os_300 on os_0 fails AAA threshold, ratio=$ratio", ratio < 7.0)
    }

    @Test
    fun testCalibratedBrandGraysNoColorCollapseFromProductionTokens() {
        val colors = loadColorsFromXml()

        // CIELAB lightness difference delta L* >= 15.0 between adjacent brand levels
        val lYellow = cielabL(colors["os_yellow"]!!)
        val lAmber = cielabL(colors["os_amber"]!!)
        val lOrange = cielabL(colors["os_orange"]!!)

        val deltaYellowAmber = kotlin.math.abs(lYellow - lAmber)
        val deltaAmberOrange = kotlin.math.abs(lAmber - lOrange)
        val deltaYellowOrange = kotlin.math.abs(lYellow - lOrange)

        assertTrue("Delta L* yellow-amber must be >= 15.0, was $deltaYellowAmber", deltaYellowAmber >= 15.0)
        assertTrue("Delta L* amber-orange must be >= 15.0, was $deltaAmberOrange", deltaAmberOrange >= 15.0)
        assertTrue("Delta L* yellow-orange must be >= 30.0, was $deltaYellowOrange", deltaYellowOrange >= 30.0)
    }

    @Test
    fun testZeroEpdArchitecturalInvariantsInCodebase() {
        val manifestFile = findFile("src/main/AndroidManifest.xml")
        val manifestContent = manifestFile.readText()

        // 1. AndroidManifest must enable hardware acceleration for fluid 60-120Hz HWUI pipeline
        assertTrue(
            "AndroidManifest must declare android:hardwareAccelerated=true",
            manifestContent.contains("android:hardwareAccelerated=\"true\"")
        )

        // 2. Scan Kotlin production source directory for prohibited EPD refresh hacks
        val srcDir = findFile("src/main/kotlin/com/daylight/drop")
        val ktFiles = srcDir.walk().filter { it.extension == "kt" }.toList()
        assertTrue("Must find production Kotlin source files", ktFiles.isNotEmpty())

        for (file in ktFiles) {
            val nonCommentCode = file.readLines().filterNot { line ->
                val trimmed = line.trim()
                trimmed.startsWith("*") || trimmed.startsWith("//") || trimmed.startsWith("/*")
            }.joinToString("\n")

            assertFalse(
                "File ${file.name} must not contain executable ACTION_REFRESH_SCREEN hook",
                nonCommentCode.contains("ACTION_REFRESH_SCREEN")
            )
            assertFalse(
                "File ${file.name} must not contain epd_waveform hook",
                nonCommentCode.contains("epd_waveform")
            )
        }
    }
}
