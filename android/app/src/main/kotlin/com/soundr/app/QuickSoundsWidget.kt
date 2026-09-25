package com.soundr.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.View
import android.widget.RemoteViews

/**
 * Home-screen widget: up to 8 sound buttons (4 per row; the second row shows
 * when the widget is resized to two rows or taller). Tapping one plays it
 * natively via [QuickSoundPlayer] without opening the app.
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
        if (intent.action != ACTION_PLAY) {
            super.onReceive(context, intent)
            return
        }
        val index = intent.getIntExtra(EXTRA_INDEX, -1)
        val sound = QuickSoundStore.load(context).getOrNull(index) ?: return
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
        QuickSoundPlayer.play(context.applicationContext, sound) {
            handler.removeCallbacks(finish)
            finish.run()
        }
    }

    companion object {
        const val ACTION_PLAY = "com.soundr.app.action.PLAY_QUICK_SOUND"
        const val EXTRA_INDEX = "index"
        private const val SLOTS = 8
        private const val TWO_ROW_MIN_HEIGHT_DP = 110

        private val slotIds = intArrayOf(
            R.id.slot_0, R.id.slot_1, R.id.slot_2, R.id.slot_3,
            R.id.slot_4, R.id.slot_5, R.id.slot_6, R.id.slot_7,
        )
        private val emojiIds = intArrayOf(
            R.id.emoji_0, R.id.emoji_1, R.id.emoji_2, R.id.emoji_3,
            R.id.emoji_4, R.id.emoji_5, R.id.emoji_6, R.id.emoji_7,
        )
        private val nameIds = intArrayOf(
            R.id.name_0, R.id.name_1, R.id.name_2, R.id.name_3,
            R.id.name_4, R.id.name_5, R.id.name_6, R.id.name_7,
        )

        /** Re-renders every placed widget — called after Flutter syncs the list. */
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, QuickSoundsWidget::class.java))
            ids.forEach { update(context, manager, it) }
        }

        private fun update(context: Context, manager: AppWidgetManager, id: Int) {
            val sounds = QuickSoundStore.load(context)
            val views = RemoteViews(context.packageName, R.layout.widget_quick_sounds)

            // Portrait reports the tallest size as MAX_HEIGHT; use it to decide
            // whether there's room for the second row.
            val options = manager.getAppWidgetOptions(id)
            val height = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 0)
            val rows = if (height >= TWO_ROW_MIN_HEIGHT_DP) 2 else 1
            val visibleSlots = minOf(SLOTS, rows * 4, sounds.size)

            if (sounds.isEmpty()) {
                views.setViewVisibility(R.id.row_top, View.GONE)
                views.setViewVisibility(R.id.row_bottom, View.GONE)
                views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
                views.setOnClickPendingIntent(R.id.widget_root, openAppIntent(context))
            } else {
                views.setViewVisibility(R.id.widget_empty, View.GONE)
                views.setViewVisibility(R.id.row_top, View.VISIBLE)
                views.setViewVisibility(
                    R.id.row_bottom,
                    if (rows == 2 && sounds.size > 4) View.VISIBLE else View.GONE,
                )
                for (i in 0 until SLOTS) {
                    if (i < visibleSlots) {
                        val s = sounds[i]
                        views.setViewVisibility(slotIds[i], View.VISIBLE)
                        views.setTextViewText(emojiIds[i], s.emoji)
                        views.setTextViewText(nameIds[i], s.name)
                        views.setContentDescription(slotIds[i], "Play ${s.name}")
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
            }
            manager.updateAppWidget(id, views)
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
