package com.soundr.app

import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Flashlight + vibration for the Morse screens.
 *
 * The torch uses CameraManager.setTorchMode, which needs no CAMERA permission.
 * Every call fails soft (returns false / does nothing) so a device without a
 * flash, or with the camera busy in another app, never crashes the screen.
 */
class DeviceFeatures(private val context: Context) : MethodChannel.MethodCallHandler {

    private val cameraManager: CameraManager? by lazy {
        context.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
    }

    /** First back-facing camera with a flash unit (falls back to any with one). */
    private val torchCameraId: String? by lazy {
        val manager = cameraManager ?: return@lazy null
        try {
            val withFlash = manager.cameraIdList.filter { id ->
                manager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
            }
            withFlash.firstOrNull { id ->
                manager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_BACK
            } ?: withFlash.firstOrNull()
        } catch (e: Exception) {
            null
        }
    }

    private val vibrator: Vibrator? by lazy {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                ?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasTorch" -> result.success(torchCameraId != null)
            "setTorch" -> result.success(setTorch(call.argument<Boolean>("on") == true))
            "hasVibrator" -> result.success(vibrator?.hasVibrator() == true)
            "vibrate" -> {
                vibrate((call.argument<Int>("ms") ?: 0).toLong())
                result.success(null)
            }
            "cancelVibrate" -> {
                vibrator?.cancel()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    fun setTorch(on: Boolean): Boolean {
        val id = torchCameraId ?: return false
        return try {
            cameraManager?.setTorchMode(id, on)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun vibrate(ms: Long) {
        val v = vibrator ?: return
        if (ms <= 0 || !v.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
        } else {
            @Suppress("DEPRECATION")
            v.vibrate(ms)
        }
    }

    /** Called when the activity goes away so the torch is never left on. */
    fun release() {
        setTorch(false)
        vibrator?.cancel()
    }
}
