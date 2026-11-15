package com.soundr.app

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var deviceFeatures: DeviceFeatures? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val features = DeviceFeatures(applicationContext)
        deviceFeatures = features
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.soundr.app/device")
            .setMethodCallHandler { call, result ->
                // Keeping the screen on needs the window, so it lives here
                // rather than in DeviceFeatures (which only has app context).
                if (call.method == "keepAwake") {
                    if (call.argument<Boolean>("on") == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                } else {
                    features.onMethodCall(call, result)
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.soundr.app/quick")
            .setMethodCallHandler(QuickSoundsChannel(applicationContext))
    }

    override fun onDestroy() {
        deviceFeatures?.release()
        super.onDestroy()
    }
}
