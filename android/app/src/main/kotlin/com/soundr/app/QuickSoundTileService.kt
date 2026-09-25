package com.soundr.app

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile: each tap plays a random favourite (or a random quick
 * sound if nothing is starred yet). The subtitle shows what's playing.
 */
class QuickSoundTileService : TileService() {

    override fun onStartListening() {
        render(playing = null)
    }

    override fun onClick() {
        val sounds = QuickSoundStore.load(this)
        val pool = sounds.filter { it.favorite }.ifEmpty { sounds }
        if (pool.isEmpty()) {
            openApp()
            return
        }
        val sound = pool.random()
        render(playing = sound)
        QuickSoundPlayer.play(applicationContext, sound) { render(playing = null) }
    }

    private fun render(playing: QuickSound?) {
        val tile = qsTile ?: return
        tile.label = getString(R.string.tile_label)
        tile.state = if (playing != null) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = playing?.let { "${it.emoji} ${it.name}" }
                ?: getString(R.string.tile_subtitle)
        }
        tile.updateTile()
    }

    @SuppressLint("StartActivityAndCollapseDeprecated")
    private fun openApp() {
        val intent = (packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE)
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
