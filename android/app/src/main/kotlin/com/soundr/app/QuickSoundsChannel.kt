package com.soundr.app

import android.app.StatusBarManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.TileService
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter ↔ widget/tile bridge on `com.soundr.app/quick`:
 *  - syncQuickSounds: store the list and refresh widgets + tile
 *  - canPinWidget / pinWidget: Android 8+ "add to home screen" prompt
 *  - canAddTile / addTile: Android 13+ "add Quick Settings tile" prompt
 */
class QuickSoundsChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "syncQuickSounds" -> {
                QuickSoundStore.save(context, call.argument<String>("json") ?: "[]")
                QuickSoundsWidget.updateAll(context)
                try {
                    TileService.requestListeningState(
                        context, ComponentName(context, QuickSoundTileService::class.java)
                    )
                } catch (_: Exception) {}
                result.success(null)
            }
            "canPinWidget" -> result.success(canPinWidget())
            "pinWidget" -> {
                if (!canPinWidget()) return result.success(false)
                val ok = AppWidgetManager.getInstance(context).requestPinAppWidget(
                    ComponentName(context, QuickSoundsWidget::class.java), null, null
                )
                result.success(ok)
            }
            "canAddTile" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
            "addTile" -> addTile(result)
            else -> result.notImplemented()
        }
    }

    private fun canPinWidget(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            AppWidgetManager.getInstance(context).isRequestPinAppWidgetSupported

    /** Replies with the StatusBarManager result code, or null if unsupported. */
    private fun addTile(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return result.success(null)
        val manager = context.getSystemService(StatusBarManager::class.java)
            ?: return result.success(null)
        try {
            manager.requestAddTileService(
                ComponentName(context, QuickSoundTileService::class.java),
                context.getString(R.string.tile_label),
                Icon.createWithResource(context, R.drawable.ic_stat_soundr),
                context.mainExecutor,
            ) { code -> result.success(code) }
        } catch (e: Exception) {
            result.success(null)
        }
    }
}
