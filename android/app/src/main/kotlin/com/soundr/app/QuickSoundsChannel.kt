package com.soundr.app

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Context
import android.os.Build
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flutter ↔ home-screen widget bridge on `com.soundr.app/quick`:
 *  - syncQuickSounds: store the list and refresh every placed widget
 *  - canPinWidget / pinWidget: Android 8+ "add to home screen" prompt
 */
class QuickSoundsChannel(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "syncQuickSounds" -> {
                QuickSoundStore.save(context, call.argument<String>("json") ?: "[]")
                QuickSoundsWidget.updateAll(context)
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
            else -> result.notImplemented()
        }
    }

    private fun canPinWidget(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            AppWidgetManager.getInstance(context).isRequestPinAppWidgetSupported
}
