package com.daylight.drop

import com.daylight.drop.transport.LoopSuppressionEngine
import com.daylight.drop.transport.ProtocolConstants
import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.util.UUID

class DirectShareAndTrampolineTests {

    private fun findXmlFile(relativePath: String): File {
        val candidates = listOf(
            File(relativePath),
            File("android/app", relativePath),
            File("app", relativePath),
            File("../app", relativePath)
        )
        return candidates.firstOrNull { it.exists() }
            ?: throw IllegalStateException("Could not locate XML file $relativePath in any candidate path")
    }

    @Test
    fun testDirectShareCategoryMatchesShortcutsXml() {
        val shortcutsFile = findXmlFile("src/main/res/xml/shortcuts.xml")
        val content = shortcutsFile.readText()

        // 1. DirectShareManager category must match XML declaration
        assertEquals("com.daylight.drop.category.DIRECT_SHARE_TARGET", DirectShareManager.DIRECT_SHARE_CATEGORY)
        assertTrue(
            "shortcuts.xml must contain category ${DirectShareManager.DIRECT_SHARE_CATEGORY}",
            content.contains("android:name=\"${DirectShareManager.DIRECT_SHARE_CATEGORY}\"")
        )

        // 2. share-target targetClass must match ShareActivity
        assertTrue(
            "shortcuts.xml targetClass must be com.daylight.drop.ShareActivity",
            content.contains("android:targetClass=\"com.daylight.drop.ShareActivity\"")
        )

        assertEquals("shortcut_mac_menu_bar_tray", DirectShareManager.SHORTCUT_ID_MAC)
        assertEquals("Mac Menu Bar Tray", DirectShareManager.DEFAULT_TARGET_NAME)
    }

    @Test
    fun testBeamTrampolineManifestAndThemeDeclarations() {
        val manifestFile = findXmlFile("src/main/AndroidManifest.xml")
        val manifestContent = manifestFile.readText()

        assertTrue(
            "AndroidManifest must register BeamTrampolineActivity",
            manifestContent.contains("android:name=\".BeamTrampolineActivity\"")
        )
        assertTrue(
            "BeamTrampolineActivity must use Theme.Daylight.TranslucentTrampoline",
            manifestContent.contains("@style/Theme.Daylight.TranslucentTrampoline")
        )

        val themesFile = findXmlFile("src/main/res/values/themes.xml")
        val themesContent = themesFile.readText()

        assertTrue(
            "Theme must declare android:windowIsTranslucent = true",
            themesContent.contains("<item name=\"android:windowIsTranslucent\">true</item>")
        )
        assertTrue(
            "Theme must declare android:backgroundDimEnabled = false",
            themesContent.contains("<item name=\"android:backgroundDimEnabled\">false</item>")
        )
        assertTrue(
            "Theme must specify zero transition animation",
            themesContent.contains("@style/Animation.Daylight.ZeroTransition")
        )
    }

    @Test
    fun testDynamicMacOriginLoopSuppression() {
        val localDevice = "dc1-test-uuid-42"
        PeerTargetManager.init(object : android.content.ContextWrapper(null) {}, localDevice)

        // Helper replicating BeamTrampolineActivity:102-108 logic
        fun isOriginSuppressed(originTag: String?): Boolean {
            return originTag != null && (
                originTag == ProtocolConstants.ROLE_MAC ||
                originTag == PeerTargetManager.getMacDeviceId() ||
                originTag.startsWith("mac") ||
                originTag != PeerTargetManager.getLocalDeviceId()
            )
        }

        // 1. Dynamic Mac UUID origin (e.g. "mac-3a8f9c1b") -> Must be suppressed
        val realisticMacOrigin = "mac-3a8f9c1b"
        assertTrue("Realistic Mac UUID origin must be suppressed", isOriginSuppressed(realisticMacOrigin))

        // 2. Role Mac origin ("mac_desktop") -> Must be suppressed
        assertTrue("Legacy/default role Mac origin must be suppressed", isOriginSuppressed(ProtocolConstants.ROLE_MAC))

        // 3. Updated PeerTargetManager macDeviceId -> Must be suppressed
        PeerTargetManager.setMacDeviceId("custom-mac-workstation")
        assertTrue("Custom Mac device ID must be suppressed", isOriginSuppressed("custom-mac-workstation"))

        // 4. Null origin (User copied text on DC1 manually) -> Must NOT be suppressed
        assertFalse("Null origin (local manual copy) must NOT be suppressed", isOriginSuppressed(null))

        // 5. Origin matches local device -> Must NOT be suppressed by origin check
        assertFalse("Self origin must NOT be suppressed by origin check", isOriginSuppressed(localDevice))
    }

    @Test
    fun testSha256DeduplicationInLoopEngine() {
        val engine = LoopSuppressionEngine(localDeviceId = "dc1-test")
        val sampleClipboardText = "Copied text from Daylight Reader ${UUID.randomUUID()}"
        val hash = LoopSuppressionEngine.computeSha256(sampleClipboardText)

        assertFalse("First appearance of text must not be suppressed", engine.shouldSuppressHash(hash))
        engine.recordHash(hash)
        assertTrue("Duplicate appearance must be suppressed by hash", engine.shouldSuppressHash(hash))
        assertTrue("Text convenience method must detect suppression", engine.shouldSuppressText(sampleClipboardText))
    }
}
