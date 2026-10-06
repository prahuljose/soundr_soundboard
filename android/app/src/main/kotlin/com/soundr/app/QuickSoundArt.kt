package com.soundr.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import kotlin.math.PI
import kotlin.math.ceil
import kotlin.math.roundToInt
import kotlin.math.sin

/**
 * The little 7-bar waveform on each widget button. RemoteViews can't host
 * custom views, so the bars are drawn into a small bitmap (33 × 22 dp:
 * 3 dp bars, 2 dp gaps, pill ends) that the widget sets on an ImageView.
 * The shape is seeded by the sound id, so a sound always looks the same.
 */
object QuickSoundArt {
    /** Widget accent (the widget doesn't follow the in-app accent). */
    const val ACCENT: Int = 0xFFB7A4FF.toInt()

    private const val BARS = 7
    private const val BAR_DP = 3f
    private const val GAP_DP = 2f
    private const val HEIGHT_DP = 22f
    private const val WIDTH_DP = BARS * BAR_DP + (BARS - 1) * GAP_DP

    /** A stable seed for [id] (String.hashCode is specified, so it never changes). */
    fun seedFor(id: String): Int = Math.floorMod(id.hashCode(), 997)

    /**
     * Bar heights in dp for [seed]: a small LCG for variety under a sine
     * envelope so the middle bars are tallest (same as the design's wave()).
     */
    fun wave(seed: Int): IntArray {
        var x = seed.toLong() * 211 + 5
        return IntArray(BARS) { i ->
            x = (x * 9301 + 49297) % 233280
            val env = sin((i + 0.5) / BARS * PI)
            (4 + (0.4 + 0.6 * (x / 233280.0)) * env * 18).roundToInt()
        }
    }

    /**
     * The waveform for [id] in [color], sized for this screen's density
     * (capped at 3x: ≤ ~26 KB each, so 8 stay far below the RemoteViews
     * binder limit; the ImageView scales it up on denser screens).
     */
    fun waveBitmap(context: Context, id: String, color: Int): Bitmap {
        val d = context.resources.displayMetrics.density.coerceIn(1f, 3f)
        val w = ceil(WIDTH_DP * d).toInt().coerceAtLeast(1)
        val h = ceil(HEIGHT_DP * d).toInt().coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color }
        val radius = BAR_DP * d / 2
        val rect = RectF()
        wave(seedFor(id)).forEachIndexed { i, barDp ->
            val left = i * (BAR_DP + GAP_DP) * d
            val barH = barDp.coerceIn(BAR_DP.toInt(), HEIGHT_DP.toInt()) * d
            val top = (h - barH) / 2
            rect.set(left, top, left + BAR_DP * d, top + barH)
            canvas.drawRoundRect(rect, radius, radius, paint)
        }
        return bitmap
    }
}
