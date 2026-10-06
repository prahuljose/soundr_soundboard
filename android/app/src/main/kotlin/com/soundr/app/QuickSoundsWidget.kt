package com.soundr.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews

/**
 * Home-screen widget (artboard 15): a header (logo, "Soundr", Stop) over up
 * to 8 sound buttons, 4 per row. Each button shows a small waveform in the
 * sound's colour above its name. Tapping one plays it natively via
 * [QuickSoundPlayer] without opening the app, and the button stays lit
 * until the sound ends or Stop is tapped.
 *
 * Height decides the shape: tall → header + two rows; medium → header + one
 * row; very short (e.g. a 1-row widget in landscape) → just the buttons.
 */
class QuickSoundsWidget : AppWidgetProvider() {

    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        ids.forEach { update(context, manager, it) }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        manager: AppWidgetManager,
        id: Int,
        newOptions: Bundle,
    ) {
        update(context, manager, id)
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_PLAY -> play(context.applicationContext, intent)
            ACTION_STOP -> {
                val app = context.applicationContext
                // Stopping runs the sound's onDone, which re-renders; with
                // nothing playing, still re-render to clear a stale highlight
                // (e.g. left over from a process that was killed mid-sound).
                if (QuickSoundPlayer.playingId != null) QuickSoundPlayer.stop() else updateAll(app)
            }
            else -> super.onReceive(context, intent)
        }
    }

    private fun play(app: Context, intent: Intent) {
        val index = intent.getIntExtra(EXTRA_INDEX, -1)
        val sound = QuickSoundStore.load(app).getOrNull(index) ?: return
        // Keep the receiver alive while the sound plays (capped well inside
        // the broadcast time limit; playback itself carries on regardless).
        val pending = goAsync()
        val handler = Handler(Looper.getMainLooper())
        var done = false
        val finish = Runnable {
            if (!done) {
                done = true
                pending.finish()
            }
        }
        handler.postDelayed(finish, 9_000)
        QuickSoundPlayer.play(app, sound) {
            handler.removeCallbacks(finish)
            finish.run()
            // Replaced by another sound → that one's render shows it instead.
            if (QuickSoundPlayer.playingId == null) updateAll(app)
        }
        if (QuickSoundPlayer.playingId == sound.id) updateAll(app)
    }

    companion object {
        const val ACTION_PLAY = "com.soundr.app.action.PLAY_QUICK_SOUND"
        const val ACTION_STOP = "com.soundr.app.action.STOP_QUICK_SOUNDS"
        const val EXTRA_INDEX = "index"
        private const val SLOTS = 8

        /** Below this height (dp) the header is dropped: buttons only. */
        private const val HEADER_MIN_HEIGHT_DP = 90

        /** Header (46) + two rows of buttons ≥ 50 dp each + padding. */
        private const val TWO_ROW_MIN_HEIGHT_DP = 152

        private val slotIds = intArrayOf(
            R.id.slot_0, R.id.slot_1, R.id.slot_2, R.id.slot_3,
            R.id.slot_4, R.id.slot_5, R.id.slot_6, R.id.slot_7,
        )
        private val waveIds = intArrayOf(
            R.id.wave_0, R.id.wave_1, R.id.wave_2, R.id.wave_3,
            R.id.wave_4, R.id.wave_5, R.id.wave_6, R.id.wave_7,
        )
        private val nameIds = intArrayOf(
            R.id.name_0, R.id.name_1, R.id.name_2, R.id.name_3,
            R.id.name_4, R.id.name_5, R.id.name_6, R.id.name_7,
        )

        /** Re-renders every placed widget — after a sync, a tap, or playback ending. */
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, QuickSoundsWidget::class.java))
            ids.forEach { update(context, manager, it) }
        }

        private data class Shape(val header: Boolean, val rows: Int)

        private fun shapeFor(heightDp: Int): Shape = when {
            heightDp <= 0 -> Shape(header = true, rows = 1) // size not reported yet
            heightDp < HEADER_MIN_HEIGHT_DP -> Shape(header = false, rows = 1)
            heightDp < TWO_ROW_MIN_HEIGHT_DP -> Shape(header = true, rows = 1)
            else -> Shape(header = true, rows = 2)
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val sounds = QuickSoundStore.load(context)
            val playingId = QuickSoundPlayer.playingId

            // Portrait reports its height as MAX_HEIGHT, landscape as
            // MIN_HEIGHT; give the launcher a layout for each.
            val options = manager.getAppWidgetOptions(id)
            val portraitHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
            val landscapeHeight = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 0)
            val portrait = shapeFor(portraitHeight)
            val landscape = if (landscapeHeight > 0) shapeFor(landscapeHeight) else portrait

            // One bitmap per sound, shared by both layouts so RemoteViews
            // sends each only once (its bitmap cache dedupes by identity).
            val waves = arrayOfNulls<Bitmap>(SLOTS)
            val waveAt = { i: Int ->
                waves[i] ?: sounds[i].let { s ->
                    val color = if (s.id == playingId) QuickSoundArt.ACCENT else s.color
                    QuickSoundArt.waveBitmap(context, s.id, color)
                }.also { waves[i] = it }
            }

            val views = if (portrait == landscape) {
                build(context, sounds, portrait, playingId, waveAt)
            } else {
                RemoteViews(
                    build(context, sounds, landscape, playingId, waveAt),
                    build(context, sounds, portrait, playingId, waveAt),
                )
            }
            manager.updateAppWidget(id, views)
        }

        private fun build(
            context: Context,
            sounds: List<QuickSound>,
            shape: Shape,
            playingId: String?,
            waveAt: (Int) -> Bitmap,
        ): RemoteViews {
            val views = RemoteViews(context.packageName, R.layout.widget_quick_sounds)
            val rows = shape.rows
            val visibleSlots = minOf(SLOTS, rows * 4, sounds.size)

            views.setViewVisibility(R.id.widget_header, if (shape.header) View.VISIBLE else View.GONE)
            views.setOnClickPendingIntent(R.id.widget_brand, openAppIntent(context))
            views.setOnClickPendingIntent(R.id.widget_stop, stopIntent(context))

            if (sounds.isEmpty()) {
                views.setViewVisibility(R.id.row_top, View.GONE)
                views.setViewVisibility(R.id.row_bottom, View.GONE)
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
                // Nothing to stop; INVISIBLE keeps the header's height.
                views.setViewVisibility(R.id.widget_stop, View.INVISIBLE)
                views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context))
                return views
            }

            views.setViewVisibility(R.id.widget_empty, View.GONE)
            views.setViewVisibility(R.id.widget_stop, View.VISIBLE)
            views.setViewVisibility(R.id.row_top, View.VISIBLE)
            views.setViewVisibility(
                R.id.row_bottom,
                if (rows == 2 && sounds.size > 4) View.VISIBLE else View.GONE,
            )
            for (i in 0 until SLOTS) {
                if (i < visibleSlots) {
                    val s = sounds[i]
                    val playing = s.id == playingId
                    views.setViewVisibility(slotIds[i], View.VISIBLE)
                    views.setInt(
                        slotIds[i], "setBackgroundResource",
                        if (playing) R.drawable.widget_tile_playing else R.drawable.widget_tile,
                    )
                    views.setImageViewBitmap(waveIds[i], waveAt(i))
                    views.setTextViewText(nameIds[i], s.name)
                    views.setContentDescription(
                        slotIds[i],
                        if (playing) "${s.name}, playing" else "Play ${s.name}",
                    )
                    views.setOnClickPendingIntent(slotIds[i], playIntent(context, i))
                } else {
                    // A part-filled second row keeps quarter-width tiles
                    // (INVISIBLE holds the space); a short first row
                    // lets its tiles stretch to fill the widget (GONE).
                    views.setViewVisibility(
                        slotIds[i],
                        if (i >= 4 && i < rows * 4) View.INVISIBLE else View.GONE,
                    )
                }
            }
            return views
        }

        private fun playIntent(context: Context, index: Int): PendingIntent {
            val intent = Intent(context, QuickSoundsWidget::class.java).apply {
                action = ACTION_PLAY
                putExtra(EXTRA_INDEX, index)
                // Unique data so each slot gets its own PendingIntent.
                data = Uri.parse("soundr://quick-sound/$index")
            }
            return PendingIntent.getBroadcast(
                context, index, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun stopIntent(context: Context): PendingIntent {
            val intent = Intent(context, QuickSoundsWidget::class.java).apply {
                action = ACTION_STOP
                data = Uri.parse("soundr://quick-sound/stop")
            }
            return PendingIntent.getBroadcast(
                context, 200, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun openAppIntent(context: Context): PendingIntent {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: Intent(context, MainActivity::class.java)
            return PendingIntent.getActivity(
                context, 100, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
