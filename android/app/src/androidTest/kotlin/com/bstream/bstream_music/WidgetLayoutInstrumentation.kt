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
import android.graphics.Color
import android.graphics.Rect
import android.graphics.drawable.BitmapDrawable
import android.os.Bundle
import android.os.Build
import android.view.View
import android.view.ViewGroup
import android.view.animation.Transformation
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.ViewFlipper
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
            } finally {
                try {
                    // Queue/artwork fixtures intentionally exercise update()
                    // against the real launcher provider; restore its host
                    // view from the app's untouched production preferences.
                    BStreamMusicWidget.refresh(
                        targetContext,
                        queueChanged = true,
                        focusQueue = true,
                    )
                } catch (restoreError: Throwable) {
                    if (failure == null) failure = restoreError
                    else failure?.addSuppressed(restoreError)
                }
            }
        }
        val result = Bundle()
        if (failure == null) {
            result.putString("stream", "WIDGET_LAYOUT_OK: $cases production cases passed (sizes, text, controls, rotation, font scaling, artwork transitions).")
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
            Case("compact-small", 250, 64),
            Case("compact-wide", 370, 64),
            Case("compact-tall-small", 250, 79),
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
            if (size == BStreamWidgetLayout.QUEUE) {
                check(label != null && label.visibility == View.GONE) { "${case.name}: queue layout still shows the player name" }
                check(song.text.toString() == if (case.empty) (if (case.english) "Not playing" else "Sin reproducción") else title)
                check(artistView.visibility == View.VISIBLE)
                check(artistView.text.toString() == if (case.empty) (if (case.english) "Tap to open" else "Toca para abrir") else artist)
                check(song.lineCount == 1 && artistView.lineCount == 1) { "${case.name}: queue metadata wraps" }
                val cover = content.findViewById<View>(R.id.widget_artwork)
                check(bounds(cover, parent).top == (10 * density).roundToInt()) { "${case.name}: queue header does not retain its 10dp top inset" }
                val controls = content.findViewById<LinearLayout>(R.id.widget_controls)
                val controlsBounds = bounds(controls, parent)
                check(controlsBounds.top >= bounds(artistView, parent).bottom) {
                    "${case.name}: queue controls overlap the artist"
                }
                check(controlsBounds.bottom <= height)
                val previous = content.findViewById<View>(R.id.widget_previous)
                val next = content.findViewById<View>(R.id.widget_next)
                check(abs((bounds(previous, parent).left + bounds(next, parent).right) / 2f - (controlsBounds.left + controlsBounds.right) / 2f) <= density)
                check(content.findViewById<View>(R.id.widget_repeat).visibility == View.GONE)
                check(content.findViewById<View>(R.id.widget_favorite).visibility == View.GONE)
                val queueTitle = content.findViewById<View>(R.id.widget_queue_title)
                val queue = content.findViewById<View>(R.id.widget_queue_list)
                check(bounds(queue, parent).top >= bounds(queueTitle, parent).bottom)
                check(bounds(queue, parent).bottom <= height)
            } else if (size.hasSeparateMetadata) {
                check(label != null && label.text.toString() == "BStream Music") { "${case.name}: player label missing" }
                check(song.text.toString() == if (case.empty) (if (case.english) "Not playing" else "Sin reproducción") else title)
                check(artistView.visibility == View.VISIBLE)
                check(artistView.text.toString() == if (case.empty) (if (case.english) "Tap to open" else "Toca para abrir") else artist)
                check(label.lineCount == 1 && song.lineCount == 1 && artistView.lineCount == 1) { "${case.name}: metadata wraps" }
                for (text in listOf(label, song, artistView)) {
                    check(text.layout.height <= text.height - text.compoundPaddingTop - text.compoundPaddingBottom + 1) {
                        "${case.name}: metadata text is clipped vertically"
                    }
                }
                check(bounds(label, parent).bottom <= bounds(song, parent).top)
                check(bounds(song, parent).bottom <= bounds(artistView, parent).top)
                val cover = content.findViewById<View>(R.id.widget_artwork)
                if (size == BStreamWidgetLayout.LARGE) {
                    check(bounds(cover, parent).width() >= (84 * density).roundToInt()) {
                        "${case.name}: intermediate artwork did not use its available size"
                    }
                }
                val controls = content.findViewById<LinearLayout>(R.id.widget_controls)
                val controlsBounds = bounds(controls, parent)
                check(controlsBounds.top >= maxOf(bounds(cover, parent).bottom, bounds(artistView, parent).bottom)) { "${case.name}: controls overlap header" }
                check(controlsBounds.bottom <= height) { "${case.name}: controls clipped vertically" }
                if (size == BStreamWidgetLayout.LARGE || size == BStreamWidgetLayout.EXPANDED) {
                    val expectedBottomInset = when (size) {
                        BStreamWidgetLayout.LARGE -> if (case.fontScale > 1f) 8 else 14
                        else -> if (case.fontScale > 1f) 10 else 16
                    }
                    val card = content.findViewById<View>(R.id.widget_card)
                    check(card.paddingBottom == (expectedBottomInset * density).roundToInt()) {
                        "${case.name}: unexpected controls bottom inset ${card.paddingBottom}px"
                    }
                    check(height - controlsBounds.bottom <= (expectedBottomInset * density).roundToInt()) {
                        "${case.name}: controls float above the bottom edge"
                    }
                }
                val first = content.findViewById<View>(R.id.widget_repeat)
                val last = content.findViewById<View>(R.id.widget_favorite)
                check(abs((bounds(first, parent).left + bounds(last, parent).right) / 2f - width / 2f) <= density) { "${case.name}: controls not centered" }
            } else {
                check(label == null && artistView.visibility == View.GONE) { "${case.name}: compact layout changed" }
                check(song.text.toString().contains(title) && song.text.toString().contains(artist))
                if (size == BStreamWidgetLayout.COMPACT_SMALL) {
                    val surface = content.findViewById<View>(R.id.widget_surface)
                    val cover = content.findViewById<View>(R.id.widget_artwork)
                    val surfaceHeight = bounds(surface, parent).height()
                    check(surfaceHeight >= (60 * density).roundToInt()) {
                        "${case.name}: compact widget surface is ${surfaceHeight / density}dp, expected at least 60dp"
                    }
                    check(bounds(cover, parent).height() >= (50 * density).roundToInt()) {
                        "${case.name}: compact artwork did not grow with its surface"
                    }
                } else if (size == BStreamWidgetLayout.COMPACT) {
                    val cover = content.findViewById<View>(R.id.widget_artwork)
                    check(bounds(cover, parent).height() >= (72 * density).roundToInt()) {
                        "${case.name}: regular compact artwork did not grow"
                    }
                }
            }
            val ids = listOf(R.id.widget_repeat, R.id.widget_previous, R.id.widget_play_pause, R.id.widget_next, R.id.widget_favorite)
            var previousRight = -1
            for (id in ids) {
                val button = content.findViewById<View>(id)
                if (button.visibility != View.GONE) {
                    val rect = bounds(button, parent)
                    check(rect.left >= previousRight && rect.right <= width) { "${case.name}: controls overlap horizontally" }
                    previousRight = rect.right
                }
                if (!case.empty || id == R.id.widget_play_pause) check(button.hasOnClickListeners()) { "${case.name}: button has no action" }
            }
            val image = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            parent.draw(Canvas(image))
            File(screenshots, "${case.name}.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
            image.recycle()
        }
        return cases.size + verifyArtworkTransitions(base, privateFiles, screenshots) +
            verifyQueueClickTemplate(base) + verifyQueueRowPresentation(base, privateFiles, screenshots) +
            verifyQueueHistoryPresentation(base, privateFiles)
    }

    private fun verifyQueueClickTemplate(context: Context): Int {
        val template = BStreamWidgetPlaybackReceiver.queueClickTemplate(context, 424242)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                check(template.isBroadcast && !template.isActivity) {
                    "Queue clicks must control playback without starting an Activity"
                }
                check(!template.isImmutable) { "Queue clicks must accept the selected row" }
            }
        } finally {
            template.cancel()
        }
        return 1
    }

    private fun verifyQueueHistoryPresentation(base: Context, directory: File): Int {
        val context = FixtureContext(base, directory)
        val queue = org.json.JSONArray()
        listOf(
            listOf("previous-2", "2", "Anterior 2", "false"),
            listOf("previous-1", "3", "Anterior 1", "false"),
            listOf("current", "4", "Reproduciendo ahora", "true"),
            listOf("next", "5", "Siguiente", "false"),
        ).forEach { (id, index, title, current) ->
            queue.put(
                org.json.JSONObject()
                    .put("id", id)
                    .put("queueIndex", index.toInt())
                    .put("title", title)
                    .put("artist", "Artista")
                    .put("isCurrent", current.toBoolean()),
            )
        }
        context.getSharedPreferences("bstream_home_widget", Context.MODE_PRIVATE)
            .edit().clear().putString("queueJson", queue.toString()).commit()
        val factory = QueueFactory(context)
        factory.onCreate()
        factory.onDataSetChanged()
        val density = context.resources.displayMetrics.density
        val current = factory.getViewAt(2)?.apply(context, FrameLayout(context))
            ?: error("Queue factory did not create the current row after playback history")
        check(current.findViewById<TextView>(R.id.widget_queue_item_title).text.toString() == "Reproduciendo ahora")
        check(current.findViewById<View>(R.id.widget_queue_item_playing_indicator).visibility == View.VISIBLE)
        val rowContainer = current.findViewById<View>(R.id.widget_queue_item_playing_indicator).parent as LinearLayout
        check(rowContainer.paddingEnd == (14 * density).roundToInt()) {
            "The queue indicator must have the additional 6dp right inset"
        }
        for (position in listOf(0, 1, 3)) {
            val row = factory.getViewAt(position)?.apply(context, FrameLayout(context))
                ?: error("Queue row $position is missing")
            check(row.findViewById<View>(R.id.widget_queue_item_playing_indicator).visibility == View.GONE) {
                "Only the current track should show the active marker"
            }
        }
        factory.onDestroy()
        return 1
    }

    private fun verifyQueueRowPresentation(base: Context, directory: File, screenshots: File): Int {
        val context = FixtureContext(base, directory)
        val prefs = context.getSharedPreferences("bstream_home_widget", Context.MODE_PRIVATE)
        prefs.edit().clear()
            .putInt("accent", Color.rgb(68, 138, 255))
            .putString(
                "queueJson",
                """[{"id":"current","queueIndex":0,"title":"Reproduciendo ahora","artist":"Artista actual","artworkPath":""},{"id":"next","queueIndex":1,"title":"Siguiente canción","artist":"Artista siguiente","artworkPath":""}]""",
            )
            .commit()
        val factory = QueueFactory(context)
        factory.onCreate()
        factory.onDataSetChanged()
        val density = context.resources.displayMetrics.density
        val width = (370 * density).roundToInt()
        val height = (72 * density).roundToInt()
        val active = factory.getViewAt(0)?.apply(context, FrameLayout(context))
            ?: error("Queue factory did not create the current song row")
        active.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
        active.layout(0, 0, width, height)
        check(active.findViewById<View>(R.id.widget_queue_item_playing_indicator).visibility == View.VISIBLE) {
            "Current queue row must show its playing indicator"
        }
        check(active.background != null) { "Current queue row must use the active rounded surface" }
        check(active.findViewById<TextView>(R.id.widget_queue_item_title).text.toString() == "Reproduciendo ahora")
        val image = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        active.draw(Canvas(image))
        File(screenshots, "queue-current-row.png").outputStream().use { image.compress(Bitmap.CompressFormat.PNG, 100, it) }
        image.recycle()

        val inactive = factory.getViewAt(1)?.apply(context, FrameLayout(context))
            ?: error("Queue factory did not create the next song row")
        check(inactive.findViewById<View>(R.id.widget_queue_item_playing_indicator).visibility == View.GONE) {
            "Inactive queue rows must hide the playing indicator"
        }
        factory.onDestroy()
        return 1
    }

    private fun verifyArtworkTransitions(base: Context, directory: File, screenshots: File): Int {
        val context = FixtureContext(base, directory)
        val prefs = context.getSharedPreferences("bstream_home_widget", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        fun source(name: String, color: Int): File {
            val bitmap = Bitmap.createBitmap(80, 80, Bitmap.Config.ARGB_8888)
            bitmap.eraseColor(color)
            return File(directory, "$name.png").also { file ->
                file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
        }
        val red = source("red", Color.RED)
        val blue = source("blue", Color.BLUE)
        fun metadata(id: String) = mapOf(
            "trackId" to id, "title" to id, "artist" to "Artwork transition",
            "isPlaying" to true, "accentColor" to Color.WHITE,
        )
        fun snapshot(name: String): Pair<Bitmap, Bitmap> {
            val options = Bundle().apply {
                putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 370)
                putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 80)
            }
            val parent = FrameLayout(context)
            val content = BStreamMusicWidget.renderForOptions(context, options).apply(context, parent)
            parent.addView(content)
            val density = context.resources.displayMetrics.density
            val width = (370 * density).roundToInt()
            val height = (80 * density).roundToInt()
            parent.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            parent.layout(0, 0, width, height)
            val screenshot = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            parent.draw(Canvas(screenshot))
            File(screenshots, "$name.png").outputStream().use { screenshot.compress(Bitmap.CompressFormat.PNG, 100, it) }
            screenshot.recycle()
            val slot = prefs.getInt("coverSlot", 0)
            val cover = ((content.findViewById<ViewFlipper>(R.id.widget_artwork).getChildAt(slot) as ImageView).drawable as BitmapDrawable).bitmap
            val background = ((content.findViewById<ViewFlipper>(R.id.widget_backdrop).getChildAt(slot) as ImageView).drawable as BitmapDrawable).bitmap
            return cover to background
        }

        BStreamMusicWidget.update(context, metadata("red"))
        BStreamMusicWidget.updateArtwork(context, mapOf("trackId" to "red", "artworkPath" to red.path))
        val before = snapshot("transition-before")
        BStreamMusicWidget.update(context, metadata("blue"))
        check(prefs.getBoolean("hasCover", false)) { "Changing track discarded the last valid artwork" }
        val pending = snapshot("transition-pending")
        check(pending.first.sameAs(before.first) && pending.second.sameAs(before.second)) {
            "The artwork or its background flashes before the replacement is ready"
        }
        BStreamMusicWidget.updateArtwork(context, mapOf("trackId" to "blue", "artworkPath" to File(directory, "missing").path))
        BStreamMusicWidget.updateArtwork(context, mapOf("trackId" to "red", "artworkPath" to blue.path))
        val failed = snapshot("transition-missing-stale")
        check(failed.first.sameAs(before.first) && failed.second.sameAs(before.second)) {
            "Missing or stale artwork replaced the retained cover"
        }
        BStreamMusicWidget.updateArtwork(context, mapOf("trackId" to "blue", "artworkPath" to blue.path))
        val after = snapshot("transition-after")
        check(Color.blue(after.first.getPixel(20, 20)) > 240 && Color.red(after.first.getPixel(20, 20)) < 15)
        check(!after.second.sameAs(before.second)) { "The new cover did not update the background" }
        check(!File(directory, "bstream_widget_cover.jpg.tmp").exists()) { "Incomplete artwork file left behind" }
        BStreamMusicWidget.update(context, metadata(""))
        check(!prefs.getBoolean("hasCover", true)) { "Clearing playback retained artwork" }

        // Exercise reapply, as used by an actual launcher, rather than only
        // inflating the final image. Both surfaces must fade on the host.
        BStreamMusicWidget.update(context, metadata("red"))
        BStreamMusicWidget.updateArtwork(context, mapOf("trackId" to "red", "artworkPath" to red.path))
        val options = Bundle().apply {
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, 370)
            putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, 80)
        }
        val parent = FrameLayout(context)
        val content = BStreamMusicWidget.renderForOptions(context, options).apply(context, parent)
        parent.addView(content)
        val coverFlipper = content.findViewById<ViewFlipper>(R.id.widget_artwork)
        val backgroundFlipper = content.findViewById<ViewFlipper>(R.id.widget_backdrop)
        val previousSlot = coverFlipper.displayedChild
        BStreamMusicWidget.update(context, metadata("blue"))
        BStreamMusicWidget.updateArtwork(context, mapOf("trackId" to "blue", "artworkPath" to blue.path))
        BStreamMusicWidget.renderForOptions(context, options, animateArtwork = true).reapply(context, content)
        check(coverFlipper.displayedChild != previousSlot && backgroundFlipper.displayedChild == coverFlipper.displayedChild)
        val coverAnimation = coverFlipper.currentView.animation
        val backgroundAnimation = backgroundFlipper.currentView.animation
        check(coverAnimation != null && backgroundAnimation != null) { "Launcher reapply did not start a crossfade" }
        check(coverAnimation.duration == 240L && backgroundAnimation.duration == 240L)
        check(coverFlipper.getChildAt(previousSlot).animation != null) { "Outgoing artwork disappeared instead of fading" }
        val fade = coverFlipper.inAnimation
        fade.startTime = 1000L
        val start = Transformation()
        val middle = Transformation()
        val end = Transformation()
        fade.getTransformation(1000L, start)
        fade.getTransformation(1120L, middle)
        fade.getTransformation(1240L, end)
        check(start.alpha < 0.01f && middle.alpha > 0.1f && middle.alpha < 0.99f && end.alpha > 0.99f) {
            "The native fade does not interpolate the artwork opacity"
        }
        BStreamMusicWidget.renderForOptions(context, options).reapply(context, content)
        check(coverFlipper.currentView.animation === coverAnimation && coverAnimation.startTime == 1000L) {
            "A metadata-only update restarted the artwork animation"
        }
        return 8
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
