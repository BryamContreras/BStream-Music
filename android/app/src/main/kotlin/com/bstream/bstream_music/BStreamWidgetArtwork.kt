package com.bstream.bstream_music

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import java.io.File
import kotlin.math.abs
import kotlin.math.min

/** Bounded square artwork shared by the widget header and its queue rows. */
internal object BStreamWidgetArtwork {
    fun decode(file: File, targetSize: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        // Leave enough source pixels for removing 4:3 thumbnail letterboxing.
        while (min(bounds.outWidth, bounds.outHeight) / (sample * 2) >= targetSize * 4 / 3) {
            sample *= 2
        }
        val decoded = BitmapFactory.decodeFile(
            file.path,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: return null
        try {
            val content = Rect(0, 0, decoded.width, decoded.height)
            // YouTube's 4:3 renditions can contain a 16:9 image with black
            // strips. Center-cropping those strips alone leaves a black frame
            // around square album art. Square originals keep their framing.
            if (abs(decoded.width.toFloat() / decoded.height - 4f / 3f) < .02f) {
                val inset = (decoded.height - decoded.width * 9 / 16) / 2
                if (inset > 1 && hasDarkBars(decoded, inset)) {
                    content.top += inset
                    content.bottom -= inset
                }
            }
            val side = min(content.width(), content.height())
            val left = content.left + (content.width() - side) / 2
            val top = content.top + (content.height() - side) / 2
            val size = min(targetSize, side).coerceAtLeast(1)
            val square = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
            Canvas(square).drawBitmap(
                decoded,
                Rect(left, top, left + side, top + side),
                Rect(0, 0, size, size),
                Paint(Paint.FILTER_BITMAP_FLAG or Paint.DITHER_FLAG),
            )
            return square
        } finally {
            decoded.recycle()
        }
    }

    private fun hasDarkBars(bitmap: Bitmap, inset: Int): Boolean {
        for (step in 1..8) {
            val x = (bitmap.width * step / 9).coerceAtMost(bitmap.width - 1)
            for (y in intArrayOf(inset / 2, bitmap.height - 1 - inset / 2)) {
                val color = bitmap.getPixel(x, y)
                if (Color.red(color) > 24 || Color.green(color) > 24 || Color.blue(color) > 24) {
                    return false
                }
            }
        }
        return true
    }
}
