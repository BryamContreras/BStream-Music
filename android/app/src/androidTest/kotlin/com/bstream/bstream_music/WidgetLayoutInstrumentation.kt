package com.bstream.bstream_music

import android.app.Activity
import android.app.Instrumentation
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import java.io.File
import kotlin.math.abs
import kotlin.math.roundToInt

/** Runs production RemoteViews on Android without touching real widget data or playback. */
class WidgetLayoutInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        start()
    }

    override fun onStart() {
        var failure: Throwable? = null
        var cases = 0
        runOnMainSync {
            try {
                cases = verifyLayouts()
            } catch (error: Throwable) {
                failure = error
            }
        }
        val result = Bundle()
        if (failure == null) {
            result.putString("stream", "WIDGET_LAYOUT_OK: $cases production layouts passed (sizes, text, controls, rotation, font scaling).")
            finish(Activity.RESULT_OK, result)
        } else {
            result.putString("stream", "WIDGET_LAYOUT_FAILED: ${failure!!.stackTraceToString()}")
            finish(Activity.RESULT_CANCELED, result)
        }
    }

    private fun verifyLayouts(): Int {
        val base = targetContext
        val privateFiles = File(base.cacheDir, "widget_layout_native_test").apply { mkdirs() }
        val screenshots = File(base.getExternalFilesDir(null), "widget-layout-tests").apply { mkdirs() }
        val artwork = BitmapFactory.decodeStream(base.assets.open("flutter_assets/assets/icons/bstream_icon.png"))
        File(privateFiles, "bstream_widget_cover.jpg").outputStream().use {
            artwork.compress(Bitmap.CompressFormat.JPEG, 84, it)
        }
        artwork.recycle()
        val cases = listOf(
            Case("compact-small", 250, 56),
            Case("compact-wide", 370, 56),
            Case("compact", 280, 80),
            Case("compact-high", 370, 149),
            Case("large-narrow", 250, 150),
            Case("large-before-boundary", 370, 164),
            Case("large-narrow-boundary", 339, 165),
            Case("expanded-min", 340, 165),
            Case("expanded", 370, 220),
            Case("expanded-tall", 400, 320),
            Case("large-narrow-tall", 260, 320),
            Case("expanded-long-text", 340, 165, longText = true),
            Case("large-long-text", 250, 150, longText = true),
            Case("expanded-large-font", 340, 165, fontScale = 1.5f, longText = true),
            Case("large-large-font", 250, 150, fontScale = 1.5f, longText = true),
            Case("expanded-empty", 370, 220, empty = true),
            Case("expanded-empty-english", 370, 220, empty = true, english = true),
            Case("landscape-large", 370, 220, landscape = true),
            Case("rotate-portrait", 370, 220, rangedOptions = true),
            Case("rotate-landscape", 250, 80, landscape = true, rangedOptions = true),
        )
        for (case in cases) {
            val configuration = Configuration(base.resources.configuration).apply {
                orientation = if (case.landscape) Configuration.ORIENTATION_LANDSCAPE else Configuration.ORIENTATION_PORTRAIT
                fontScale = case.fontScale
            }
            val context = FixtureContext(base.createConfigurationContext(configuration), privateFiles)
            val prefs = context.getSharedPreferences("bstream_home_widget", Context.MODE_PRIVATE)
            val title = if (case.empty) "" else if (case.longText) "Un nombre de canción realmente largo para probar que no ocupa dos líneas" else "Mi canción favorita"
            val artist = if (case.longText) "Un artista con nombre muy largo y muchos colaboradores" else "BStream Music"
            prefs.edit().clear()
                .putString("trackId", "native-layout-fixture")
                .putString("title", title)
                .putString("artist", artist)
                .putString("language", if (case.english) "en" else "es")
                .putBoolean("hasCover", true)
                .putBoolean("playing", true)
                .putBoolean("favorite", true)
                .putString("repeatMode", "all")
                .commit()
            val options = Bundle().apply {
                putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, if (case.rangedOptions) 250 else case.width)
                putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, if (case.rangedOptions) 370 else case.width)
                putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, if (case.rangedOptions) 80 else case.height)
                putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, if (case.rangedOptions) 220 else case.height)
            }
            val views = BStreamMusicWidget.renderForOptions(context, options)
            val parent = FrameLayout(context)
            val content = views.apply(context, parent)
            parent.addView(content)
            val density = context.resources.displayMetrics.density
            val width = (case.width * density).roundToInt()
            val height = (case.height * density).roundToInt()
            parent.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            parent.layout(0, 0, width, height)

            val song = content.findViewById<TextView>(R.id.widget_title)
            val artistView = content.findViewById<TextView>(R.id.widget_artist)
            val label: TextView? = content.findViewById<TextView>(R.id.widget_player_name)
            val size = BStreamWidgetLayout.forSize(case.width, case.height)
            if (size.hasSeparateMetadata) {
                check(label != null && label.text.toString() == "BStream Music") { "${case.name}: player label missing" }
                check(song.text.toString() == if (case.empty) (if (case.english) "Not playing" else "Sin reproducción") else title)
                check(artistView.visibility == View.VISIBLE)
                check(artistView.text.toString() == if (case.empty) (if (case.english) "Tap to open" else "Toca para abrir") else artist)
                check(label.lineCount == 1 && song.lineCount == 1 && artistView.lineCount == 1) { "${case.name}: metadata wraps" }
                check(bounds(label, parent).bottom <= bounds(song, parent).top)
                check(bounds(song, parent).bottom <= bounds(artistView, parent).top)
                val cover = content.findViewById<View>(R.id.widget_artwork)
                val controls = content.findViewById<LinearLayout>(R.id.widget_controls)
                val controlsBounds = bounds(controls, parent)
                check(controlsBounds.top >= maxOf(bounds(cover, parent).bottom, bounds(artistView, parent).bottom)) { "${case.name}: controls overlap header" }
                check(controlsBounds.bottom <= height) { "${case.name}: controls clipped vertically" }
                val first = content.findViewById<View>(R.id.widget_repeat)
                val last = content.findViewById<View>(R.id.widget_favorite)
                check(abs((bounds(first, parent).left + bounds(last, parent).right) / 2f - width / 2f) <= density) { "${case.name}: controls not centered" }
            } else {
                check(label == null && artistView.visibility == View.GONE) { "${case.name}: compact layout changed" }
                check(song.text.toString().contains(title) && song.text.toString().contains(artist))
            }
            val ids = listOf(R.id.widget_repeat, R.id.widget_previous, R.id.widget_play_pause, R.id.widget_next, R.id.widget_favorite)
            var previousRight = -1
            for (id in ids) {
                val button = content.findViewById<View>(id)
                val rect = bounds(button, parent)
                check(rect.left >= previousRight && rect.right <= width) { "${case.name}: controls overlap horizontally" }
                previousRight = rect.right
                if (!case.empty || id == R.id.widget_play_pause) check(button.hasOnClickListeners()) { "${case.name}: button has no action" }
            }
            val image = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            parent.draw(Canvas(image))
            File(screenshots, "${case.name}.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            image.recycle()
        }
        return cases.size
    }

    private fun bounds(view: View, parent: ViewGroup): Rect = Rect(0, 0, view.width, view.height).also {
        parent.offsetDescendantRectToMyCoords(view, it)
    }

    private class FixtureContext(base: Context, private val directory: File) : ContextWrapper(base) {
        override fun getFilesDir(): File = directory
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences(if (name == "bstream_home_widget") "bstream_widget_layout_native_test" else name, mode)
    }

    private data class Case(
        val name: String, val width: Int, val height: Int,
        val fontScale: Float = 1f, val longText: Boolean = false,
        val empty: Boolean = false, val english: Boolean = false,
        val landscape: Boolean = false, val rangedOptions: Boolean = false,
    )
}
