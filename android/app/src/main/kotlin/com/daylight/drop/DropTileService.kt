package com.daylight.drop

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log

/**
 * DropTileService: Sol:OS Quick Settings pull-down shade tile for 1-tap clipboard beaming.
 *
 * Requirements & Constraints:
 * 1. Declared in AndroidManifest.xml with `android.service.quicksettings.action.QS_TILE`
 *    and permission `android.permission.BIND_QUICK_SETTINGS_TILE`.
 * 2. Android 13 Background Clipboard Restriction: On Android 13 (API 33), a background service
 *    or TileService calling `ClipboardManager.getPrimaryClip()` returns null or triggers a
 *    security warning because the process lacks window focus.
 * 3. Solution: onClick() dispatches `startActivityAndCollapse()` targeting `BeamTrampolineActivity`.
 *    This collapses the notification shade and launches the ephemeral translucent activity,
 *    which acquires window focus (<25ms) and reads the clipboard legitimately.
 * 4. State Management: Displays STATE_ACTIVE ("Connected") when a Mac peer is discovered/connected,
 *    and STATE_INACTIVE ("Offline") when disconnected.
 */
class DropTileService : TileService() {

    companion object {
        private const val TAG = "DropTileService"
    }

    override fun onStartListening() {
        super.onStartListening()
        updateTileState()
    }

    override fun onStopListening() {
        super.onStopListening()
    }

    override fun onTileAdded() {
        super.onTileAdded()
        updateTileState()
    }

    /**
     * Updates the Quick Settings tile visual state, label, subtitle, and icon.
     */
    private fun updateTileState() {
        val tile = qsTile ?: return
        val isConnected = PeerTargetManager.isMacAvailable()

        tile.state = if (isConnected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_drop_label)
        
        // Subtitle available on API 29+ (DC1 runs Android 13 / API 33)
        tile.subtitle = if (isConnected) {
            getString(R.string.tile_drop_subtitle_connected)
        } else {
            getString(R.string.tile_drop_subtitle_offline)
        }

        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile_drop)
        tile.contentDescription = getString(R.string.tile_drop_content_description)
        tile.updateTile()
        Log.d(TAG, "Tile state updated: active=$isConnected, subtitle=${tile.subtitle}")
    }

    /**
     * Handles user click on the Quick Settings tile.
     * Invokes `startActivityAndCollapse()` to collapse the notification shade and
     * launch BeamTrampolineActivity with FLAG_ACTIVITY_NEW_TASK.
     */
    override fun onClick() {
        super.onClick()
        Log.i(TAG, "Quick Settings tile clicked — collapsing shade and launching trampoline")

        val intent = Intent(this, BeamTrampolineActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(BeamTrampolineActivity.EXTRA_TRIGGER_SOURCE, "qs_tile")
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // Android 14+ (API 34) requires PendingIntent for startActivityAndCollapse
            val pendingIntent = PendingIntent.getActivity(
                this,
                0,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            // Android 13 (API 33 / DC1 Target) standard API
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
