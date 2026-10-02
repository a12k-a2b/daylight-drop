package com.daylight.drop

import com.daylight.drop.transport.AndroidChannelType
import com.daylight.drop.transport.ProtocolConstants
import org.junit.Assert.*
import org.junit.Test
import java.io.File

class DaylightDropServiceLifecycleTests {

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
    fun testServiceConstantsAndIntentActions() {
        assertEquals(8766, DaylightDropService.NOTIFICATION_ID)
        assertEquals("daylight_drop_service_channel", DaylightDropService.CHANNEL_SERVICE)
        assertEquals("daylight_prompts", DaylightDropService.CHANNEL_PROMPTS)
        assertEquals("daylight_drops", DaylightDropService.CHANNEL_DROPS)

        assertEquals("com.daylight.drop.action.START", DaylightDropService.ACTION_START)
        assertEquals("com.daylight.drop.action.STOP", DaylightDropService.ACTION_STOP)
        assertEquals("com.daylight.drop.action.SYNC_SCREENSHOT", DaylightDropService.ACTION_SYNC_SCREENSHOT)
        assertEquals("com.daylight.drop.action.COPY_CLIPBOARD", DaylightDropService.ACTION_COPY_CLIPBOARD)
    }

    @Test
    fun testServiceManifestDeclarationAndForegroundType() {
        val manifestFile = findXmlFile("src/main/AndroidManifest.xml")
        val content = manifestFile.readText()

        // Service declaration in AndroidManifest
        assertTrue(
            "AndroidManifest must declare DaylightDropService",
            content.contains("android:name=\".DaylightDropService\"")
        )

        // Foreground service type must be dataSync for companion syncing
        assertTrue(
            "DaylightDropService must declare foregroundServiceType=dataSync",
            content.contains("android:foregroundServiceType=\"dataSync\"")
        )
    }

    @Test
    fun testWakeLockCompanionMethodsSafeWhenServiceNull() {
        // When service is not instantiated, safe companion methods should not throw
        try {
            DaylightDropService.acquireWakeLock(1000L)
            DaylightDropService.releaseWakeLock()
            assertTrue(true)
        } catch (e: Exception) {
            fail("WakeLock companion helpers threw exception when service is null: ${e.message}")
        }
    }

    @Test
    fun testPeerTargetManagerStateTransitions() {
        val initialId = PeerTargetManager.getLocalDeviceId()
        assertTrue(initialId.startsWith("dc1-"))

        // Host mutation
        PeerTargetManager.setActiveHost("192.168.1.100")
        assertEquals("192.168.1.100", PeerTargetManager.getActiveHost())

        // Mac ID mutation
        PeerTargetManager.setMacDeviceId("mac-99aabbcc")
        assertEquals("mac-99aabbcc", PeerTargetManager.getMacDeviceId())

        // Connection state mutation
        PeerTargetManager.setMacConnected(false)
        assertFalse(PeerTargetManager.isMacAvailable())
        PeerTargetManager.setMacConnected(true)
        assertTrue(PeerTargetManager.isMacAvailable())

        // Custom device ID initialization
        PeerTargetManager.init(object : android.content.ContextWrapper(null) {}, "dc1-custom-hardware-serial")
        assertEquals("dc1-custom-hardware-serial", PeerTargetManager.getLocalDeviceId())
    }

    @Test
    fun testAndroidChannelTypeDescriptions() {
        assertEquals("USB (ADB Tunnel)", AndroidChannelType.USB.description)
        assertEquals("Wi-Fi (mDNS)", AndroidChannelType.WIFI.description)
    }

    @Test
    fun testPortAllocationAsymmetry() {
        // macOS is 8765, DC1 is 8766
        assertEquals(8765, ProtocolConstants.MAC_PORT)
        assertEquals(8766, ProtocolConstants.ANDROID_PORT)
        assertNotEquals(ProtocolConstants.MAC_PORT, ProtocolConstants.ANDROID_PORT)
    }
}
