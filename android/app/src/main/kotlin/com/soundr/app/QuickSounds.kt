package com.soundr.app

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import java.io.File

/**
 * One sound the home-screen widget and Quick Settings tile can play.
 * [asset] is a Flutter asset key (built-in sounds); [path] is a file on disk
 * (the user's own clips). Trim points are in milliseconds.
 */
data class QuickSound(
    val id: String,
    val name: String,
    val emoji: String,
    val asset: String?,
    val path: String?,
    val startMs: Int,
    val endMs: Int,
    val favorite: Boolean,
)

/**
 * The list Flutter hands over via [QuickSoundsChannel] — favourites first,
 * then most-played, then a few starters, so the widget is never empty.
 */
object QuickSoundStore {
    private const val PREFS = "soundr_quick_sounds"
    private const val KEY = "items"

    fun save(context: Context, json: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, json).apply()
    }

    fun load(context: Context): List<QuickSound> {
        val json = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, null) ?: return emptyList()
        return try {
            val arr = JSONArray(json)
            (0 until arr.length()).map { i ->
                val o = arr.getJSONObject(i)
                QuickSound(
                    id = o.getString("id"),
                    name = o.getString("name"),
                    emoji = o.optString("emoji", "🔊"),
                    asset = o.optString("asset").ifEmpty { null },
                    path = o.optString("path").ifEmpty { null },
                    startMs = o.optInt("startMs", 0),
                    endMs = o.optInt("endMs", 0),
                    favorite = o.optBoolean("favorite", false),
                )
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
}

/**
 * Plays one quick sound at a time with MediaPlayer, straight from the APK's
 * Flutter assets — no Flutter engine needed, so widget and tile taps are
 * instant even when the app isn't running.
 */
object QuickSoundPlayer {
    private val handler = Handler(Looper.getMainLooper())
    private var current: Session? = null

    private class Session(val player: MediaPlayer, val onDone: () -> Unit) {
        var finished = false
        var stopTask: Runnable? = null
    }

    /** Plays [sound]; [onDone] runs exactly once when it ends, fails or is replaced. */
    fun play(context: Context, sound: QuickSound, onDone: () -> Unit = {}) {
        current?.let { finish(it) }
        val player = MediaPlayer()
        val session = Session(player, onDone)
        current = session
        try {
            player.setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            when {
                sound.path != null -> {
                    if (!File(sound.path).exists()) return finish(session)
                    player.setDataSource(sound.path)
                }
                sound.asset != null -> setAssetSource(context, player, sound.asset)
                else -> return finish(session)
            }
            player.setOnPreparedListener { mp ->
                if (sound.startMs > 0) seek(mp, sound.startMs)
                mp.start()
                if (sound.endMs > sound.startMs) {
                    val task = Runnable { finish(session) }
                    session.stopTask = task
                    handler.postDelayed(task, (sound.endMs - sound.startMs).toLong())
                }
            }
            player.setOnCompletionListener { finish(session) }
            player.setOnErrorListener { _, _, _ -> finish(session); true }
            player.prepareAsync()
        } catch (e: Exception) {
            finish(session)
        }
    }

    private fun setAssetSource(context: Context, player: MediaPlayer, asset: String) {
        val key = "flutter_assets/$asset"
        try {
            // Audio assets are stored uncompressed, so they can be streamed in place.
            context.assets.openFd(key).use { fd ->
                player.setDataSource(fd.fileDescriptor, fd.startOffset, fd.length)
            }
        } catch (e: Exception) {
            // Fallback if a build ever compresses them: copy once to the cache.
            val cached = File(context.cacheDir, "quick_sounds/" + asset.substringAfterLast('/'))
            if (!cached.exists()) {
                cached.parentFile?.mkdirs()
                context.assets.open(key).use { input ->
                    cached.outputStream().use { input.copyTo(it) }
                }
            }
            player.setDataSource(cached.absolutePath)
        }
    }

    private fun seek(player: MediaPlayer, ms: Int) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            player.seekTo(ms.toLong(), MediaPlayer.SEEK_CLOSEST)
        } else {
            player.seekTo(ms)
        }
    }

    private fun finish(session: Session) {
        if (session.finished) return
        session.finished = true
        session.stopTask?.let { handler.removeCallbacks(it) }
        try {
            session.player.stop()
        } catch (_: Exception) {}
        session.player.release()
        if (current === session) current = null
        session.onDone()
    }
}
