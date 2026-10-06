package com.soundr.app

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * One sound the home-screen widget can play.
 * [asset] is a Flutter asset key (built-in sounds); [path] is a file on disk
 * (the user's own clips). Trim points are in milliseconds. [color] is the
 * sound's category (or custom clip) colour as opaque ARGB; payloads synced
 * before it existed fall back to the widget accent.
 */
data class QuickSound(
    val id: String,
    val name: String,
    val emoji: String,
    val asset: String?,
    val path: String?,
    val startMs: Int,
    val endMs: Int,
    val color: Int = QuickSoundArt.ACCENT,
)

/**
 * The list Flutter hands over via [QuickSoundsChannel]: the user's own picks
 * (Settings → Choose widget sounds), or favourites first, then most-played,
 * then a few starters, so the widget is never empty.
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
                    color = parseColor(o),
                )
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** `color` is an ARGB number from Dart; absent or invalid → the accent. */
    private fun parseColor(o: JSONObject): Int {
        if (!o.has("color") || o.isNull("color")) return QuickSoundArt.ACCENT
        val argb = o.optLong("color", -1L)
        if (argb < 0L || argb > 0xFFFFFFFFL) return QuickSoundArt.ACCENT
        return (argb or 0xFF000000L).toInt()
    }
}

/**
 * Plays one quick sound at a time with MediaPlayer, straight from the APK's
 * Flutter assets — no Flutter engine needed, so widget taps are
 * instant even when the app isn't running.
 */
object QuickSoundPlayer {
    private val handler = Handler(Looper.getMainLooper())
    private var current: Session? = null

    private class Session(
        val soundId: String,
        val player: MediaPlayer,
        val onDone: () -> Unit,
    ) {
        var finished = false
        var stopTask: Runnable? = null
    }

    /** Id of the sound playing right now (in this process), or null. */
    val playingId: String?
        get() = current?.soundId

    /**
     * Plays [sound]; [onDone] runs exactly once when it ends, fails, is
     * stopped or is replaced. [playingId] already names the new sound when a
     * replaced sound's [onDone] runs, so listeners never see a gap.
     */
    fun play(context: Context, sound: QuickSound, onDone: () -> Unit = {}) {
        val previous = current
        val player = MediaPlayer()
        val session = Session(sound.id, player, onDone)
        current = session
        previous?.let { finish(it) }
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

    /** Stops whatever the widget is playing (its onDone still runs). */
    fun stop() {
        current?.let { finish(it) }
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
