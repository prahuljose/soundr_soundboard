# ── flutter_soloud ───────────────────────────────────────────────────────────
# Native FFI library. Keep everything in the plugin's namespace and all native
# method bindings, otherwise SoLoud.instance.init() hangs in release builds.
-keep class com.flutter.soloud.** { *; }
-keep class * extends ai.thelearninglab.soloud.** { *; }
-keepclasseswithmembernames class * {
    native <methods>;
}

# ── flutter_local_notifications ──────────────────────────────────────────────
# Plugin uses runtime reflection via resolvePlatformSpecificImplementation().
# Without these the permission request silently no-ops on Android 13+.
-keep class com.dexterous.** { *; }
-keep class * extends com.dexterous.flutterlocalnotifications.** { *; }

# ── record (audio recording plugin, also FFI-touching) ────────────────────────
-keep class com.llfbandit.record.** { *; }

# ── audio_waveforms ──────────────────────────────────────────────────────────
-keep class com.simform.audio_waveforms.** { *; }

# ── share_plus ───────────────────────────────────────────────────────────────
-keep class dev.fluttercommunity.plus.share.** { *; }

# ── permission_handler ───────────────────────────────────────────────────────
-keep class com.baseflow.permissionhandler.** { *; }

# ── path_provider ────────────────────────────────────────────────────────────
-keep class io.flutter.plugins.pathprovider.** { *; }

# ── Flutter engine internals — keep plugin registry resolution working ───────
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.embedding.** { *; }

# ── Suppress warnings about missing optional deps ────────────────────────────
-dontwarn com.google.android.play.core.**
-dontwarn org.bouncycastle.**
-dontwarn org.conscrypt.**
-dontwarn org.openjsse.**
