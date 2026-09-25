package com.soundr.app

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
            .setMethodCallHandler(features)
    }

    override fun onDestroy() {
        deviceFeatures?.release()
        super.onDestroy()
    }
}
