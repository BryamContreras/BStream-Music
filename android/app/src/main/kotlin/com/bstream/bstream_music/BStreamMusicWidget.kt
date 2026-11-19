package com.bstream.bstream_music

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.os.Build
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.RadialGradient
import android.graphics.Shader
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.system.Os
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.graphics.Typeface
import android.view.KeyEvent
import android.view.View
import android.widget.RemoteViews
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.max
import kotlin.math.roundToInt

class BStreamMusicGlassWidget : BStreamMusicWidget() {
    override val glassBackground = true
}

open class BStreamMusicWidget : AppWidgetProvider() {
    protected open val glassBackground = false

    override fun onDeleted(context: Context, appWidgetIds: IntArray) {
        appWidgetIds.forEach { pendingQueueFocus.remove(it) }
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        appWidgetIds.forEach { id ->
            appWidgetManager.updateAppWidget(id, render(context, appWidgetManager, id))
            notifyQueueChanged(context, appWidgetManager, id)
        }
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle,
    ) {
        appWidgetManager.updateAppWidget(appWidgetId, render(context, appWidgetManager, appWidgetId))
        notifyQueueChanged(context, appWidgetManager, appWidgetId)
    }

    private fun render(context: Context, manager: AppWidgetManager, id: Int): RemoteViews =
        renderForOptions(
            context, manager.getAppWidgetOptions(id),
            appWidgetId = id, focusQueue = true, glassBackground = glassBackground,
        )

    companion object {
        private const val PREFS = "bstream_home_widget"
        private const val COVER_FILE = "bstream_widget_cover.jpg"
        private class ArtworkFrame(val key: String, val cover: Bitmap?, backdrop: () -> Bitmap) {
            val background by lazy(backdrop)
        }
        private val widgetProviders = mapOf(
            BStreamMusicWidget::class.java.name to false,
            BStreamMusicGlassWidget::class.java.name to true,
        )
        private val artworkFrames = arrayOfNulls<ArtworkFrame>(2)
        private val pendingQueueFocus = ConcurrentHashMap<Int, String>()
        private val queueFocusHandler = Handler(Looper.getMainLooper())

        private fun coverFile(context: Context, slot: Int): File = File(
            context.filesDir,
            if (slot == 0) COVER_FILE else "bstream_widget_cover_alternate.jpg",
        )

        fun update(context: Context, data: Map<*, *>) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val trackId = data["trackId"] as? String ?: ""
            val previousQueue = prefs.getString("queueJson", "[]").orEmpty()
            val nextQueue = data["queueJson"] as? String ?: previousQueue
            val queueChanged = previousQueue != nextQueue
            val previousFocus = if (queueChanged) BStreamWidgetQueue.read(previousQueue).focus else null
            val queue = if (queueChanged || !prefs.contains("queueCurrentPosition")) {
                BStreamWidgetQueue.read(nextQueue)
            } else null
            val focusChanged = previousFocus != null && previousFocus != queue?.focus
            prefs.edit()
                .putString("trackId", trackId)
                .putString("title", data["title"] as? String ?: "")
                .putString("artist", data["artist"] as? String ?: "")
                .putBoolean("playing", data["isPlaying"] as? Boolean ?: false)
                .putBoolean("loading", data["isLoading"] as? Boolean ?: false)
                .putString("loadingLabel", data["loadingLabel"] as? String ?: "")
                .putBoolean("favorite", data["isFavorite"] as? Boolean ?: false)
                .putString("repeatMode", data["repeatMode"] as? String ?: "off")
                .putInt("accent", data["accentColor"] as? Int ?: 0xFFF5F7F5.toInt())
                .putString("language", data["languageCode"] as? String ?: "es")
                .apply {
                    if (queueChanged) putString("queueJson", nextQueue)
                    if (queue != null) putInt("queueCurrentPosition", queue.selectedPosition ?: 0)
                    // Keep the last complete cover and palette during a track
                    // change. The replacement arrives asynchronously.
                    if (trackId.isEmpty()) putBoolean("hasCover", false)
                }
                .apply()
            refresh(context, queueChanged = queueChanged, focusQueue = focusChanged)
        }

        fun updateArtwork(context: Context, data: Map<*, *>) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val trackId = data["trackId"] as? String ?: return
            if (trackId != prefs.getString("trackId", "")) return
            val path = data["artworkPath"] as? String ?: return
            val source = File(path)
            if (!source.isFile) return
            val bitmap = BStreamWidgetArtwork.decode(source, 384) ?: return
            saveArtwork(context, prefs, trackId, bitmap)
        }

        fun updateArtworkBytes(context: Context, data: Map<*, *>) {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val trackId = data["trackId"] as? String ?: return
            if (trackId != prefs.getString("trackId", "")) return
            val bytes = data["bytes"] as? ByteArray ?: return
            val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return
            saveArtwork(context, prefs, trackId, bitmap)
        }

        private fun saveArtwork(context: Context, prefs: android.content.SharedPreferences, trackId: String, bitmap: Bitmap) {
            val nextSlot = if (prefs.getBoolean("hasCover", false)) {
                1 - prefs.getInt("coverSlot", 0).coerceIn(0, 1)
            } else 0
            val cover = coverFile(context, nextSlot)
            val pendingCover = File(cover.parentFile, "${cover.name}.tmp")
            try {
                val palette = artworkPalette(bitmap)
                FileOutputStream(pendingCover).use { output ->
                    check(bitmap.compress(Bitmap.CompressFormat.JPEG, 84, output))
                }
                if (trackId == prefs.getString("trackId", "")) {
                    // Atomic replacement keeps launcher refreshes from reading
                    // a partially written JPEG. All updates use one worker.
                    Os.rename(pendingCover.path, cover.path)
                    artworkFrames[nextSlot] = null
                    prefs.edit()
                        .putInt("paletteBase", palette.first)
                        .putInt("paletteHighlight", palette.second)
                        .putInt("paletteBase$nextSlot", palette.first)
                        .putInt("paletteHighlight$nextSlot", palette.second)
                        .putInt("coverSlot", nextSlot)
                        .putBoolean("hasCover", true)
                        .apply()
                    refresh(context, animateArtwork = true)
                }
            } catch (_: Exception) {
                // The title and transport controls remain usable without art.
            } finally {
                pendingCover.delete()
                bitmap.recycle()
            }
        }

        fun refresh(
            context: Context,
            animateArtwork: Boolean = false,
            queueChanged: Boolean = false,
            focusQueue: Boolean = false,
        ) {
            val manager = AppWidgetManager.getInstance(context)
            widgetProviders.forEach { (provider, glassBackground) ->
                // Publish a complete stable snapshot for metadata changes. Android
                // merges partial updates into its cached views, which would replay
                // a cached setDisplayedChild animation even for a button update.
                manager.getAppWidgetIds(ComponentName(context, provider)).forEach { id ->
                    manager.updateAppWidget(
                        id,
                        renderForOptions(
                            context,
                            manager.getAppWidgetOptions(id),
                            animateArtwork,
                            appWidgetId = id,
                            focusQueue = focusQueue,
                            glassBackground = glassBackground,
                        ),
                    )
                    if (queueChanged || focusQueue) notifyQueueChanged(context, manager, id)
                }
            }
        }

        internal fun renderForOptions(
            context: Context,
            options: Bundle,
            animateArtwork: Boolean = false,
            appWidgetId: Int? = null,
            focusQueue: Boolean = false,
            glassBackground: Boolean = false,
        ): RemoteViews {
            val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            val title = prefs.getString("title", "").orEmpty()
            val artist = prefs.getString("artist", "").orEmpty()
            val isPlaying = prefs.getBoolean("playing", false)
            val isLoading = prefs.getBoolean("loading", false) && title.isNotEmpty() &&
                !prefs.getString("trackId", "").isNullOrEmpty()
            val isFavorite = prefs.getBoolean("favorite", false)
            val repeatMode = prefs.getString("repeatMode", "off").orEmpty()
            val accent = prefs.getInt("accent", 0xFFF5F7F5.toInt())
            val english = prefs.getString("language", "es") == "en"
            val heightOption = if (context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
                AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT
            } else {
                AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT
            }
            val widthOption = if (context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
                AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH
            } else {
                AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH
            }
            val currentHeight = options.getInt(
                heightOption,
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 50),
            )
            val currentWidth = options.getInt(
                widthOption,
                options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250),
            )
            val sizeCategory = BStreamWidgetLayout.forSize(currentWidth, currentHeight)
            val layout = when (sizeCategory) {
                BStreamWidgetLayout.COMPACT_SMALL -> R.layout.bstream_music_widget_compact_small_v2
                BStreamWidgetLayout.COMPACT -> R.layout.bstream_music_widget_compact_v2
                BStreamWidgetLayout.EXPANDED -> R.layout.bstream_music_widget_expanded_v2
                BStreamWidgetLayout.QUEUE -> R.layout.bstream_music_widget_queue_v2
                BStreamWidgetLayout.LARGE -> R.layout.bstream_music_widget_v2
            }
            return RemoteViews(context.packageName, layout).apply {
                if (glassBackground) {
                    setInt(R.id.widget_surface, "setBackgroundResource", R.drawable.bstream_widget_glass_background)
                    setViewVisibility(R.id.widget_backdrop, View.GONE)
                }
                bindArtwork(context, prefs, this, accent, animateArtwork, showBackdrop = !glassBackground)
                // Keep the extra lower breathing room at normal text scale. At
                // accessibility font sizes, reduce the inset so the
                // three metadata lines retain enough vertical space.
                val fontScale = context.resources.configuration.fontScale
                val density = context.resources.displayMetrics.density
                when (sizeCategory) {
                    BStreamWidgetLayout.LARGE -> {
                        val bottom = if (fontScale > 1f) 4 else 14
                        setViewPadding(
                            R.id.widget_card,
                            (10 * density).roundToInt(),
                            0,
                            (10 * density).roundToInt(),
                            (bottom * density).roundToInt(),
                        )
                    }
                    BStreamWidgetLayout.EXPANDED -> {
                        val bottom = if (fontScale > 1f) 10 else 16
                        setViewPadding(
                            R.id.widget_card,
                            (12 * density).roundToInt(),
                            (2 * density).roundToInt(),
                            (12 * density).roundToInt(),
                            (bottom * density).roundToInt(),
                        )
                    }
                    else -> Unit
                }
                val displayTitle = title.ifEmpty {
                    if (english) "Not playing" else "Sin reproducción"
                }
                val displayArtist = if (title.isEmpty()) {
                    if (english) "Tap to open" else "Toca para abrir"
                } else artist
                if (sizeCategory.hasSeparateMetadata) {
                    setTextViewText(R.id.widget_player_name, context.getString(R.string.widget_player_name))
                    setTextViewText(R.id.widget_title, displayTitle)
                    setTextViewText(R.id.widget_artist, displayArtist)
                    setViewVisibility(R.id.widget_artist, View.VISIBLE)
                } else {
                    val titleAndArtist = SpannableStringBuilder(displayTitle)
                    if (displayTitle.isNotEmpty()) {
                        titleAndArtist.setSpan(
                            StyleSpan(Typeface.BOLD),
                            0,
                            titleAndArtist.length,
                            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                        )
                    }
                    if (displayArtist.isNotBlank()) {
                        val separatorStart = titleAndArtist.length
                        titleAndArtist.append("  ·  ")
                        titleAndArtist.setSpan(
                            ForegroundColorSpan(Color.argb(190, 221, 227, 232)),
                            separatorStart,
                            titleAndArtist.length,
                            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                        )
                        val artistStart = titleAndArtist.length
                        titleAndArtist.append(displayArtist)
                        titleAndArtist.setSpan(
                            ForegroundColorSpan(Color.argb(215, 221, 227, 232)),
                            artistStart,
                            titleAndArtist.length,
                            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE,
                        )
                    }
                    setTextViewText(R.id.widget_title, titleAndArtist)
                    setViewVisibility(R.id.widget_artist, View.GONE)
                }
                if (sizeCategory == BStreamWidgetLayout.QUEUE) {
                    setViewVisibility(R.id.widget_player_name, View.GONE)
                    setViewVisibility(R.id.widget_repeat, View.GONE)
                    setViewVisibility(R.id.widget_favorite, View.GONE)
                    val (queueTitle, queueEmpty) = when (prefs.getString("language", "es")) {
                        "en" -> "Playback queue" to "No songs in the queue"
                        "pt" -> "Fila de reprodução" to "Nenhuma música na fila"
                        "fr" -> "File de lecture" to "Aucune chanson dans la file"
                        "ko" -> "재생 대기열" to "대기열에 곡이 없습니다"
                        "zh" -> "播放队列" to "队列中没有歌曲"
                        "ja" -> "再生キュー" to "キューに曲がありません"
                        else -> "Cola de reproducción" to "No hay canciones en la cola"
                    }
                    setTextViewText(R.id.widget_queue_title, queueTitle)
                    setTextViewText(R.id.widget_queue_empty, queueEmpty)
                    if (appWidgetId != null) {
                        val adapterIntent = Intent(context, BStreamMusicQueueWidgetService::class.java).apply {
                            putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, appWidgetId)
                            // Bump the adapter identity when the collection row
                            // RemoteViews schema changes so launchers discard
                            // rows cached from the previous widget version.
                            data = Uri.parse("bstream-widget://queue/$appWidgetId/rows-v5")
                        }
                        setRemoteAdapter(R.id.widget_queue_list, adapterIntent)
                        setEmptyView(R.id.widget_queue_list, R.id.widget_queue_empty)
                        val queueClickTemplate = BStreamWidgetPlaybackReceiver.queueClickTemplate(
                            context, appWidgetId,
                        )
                        setPendingIntentTemplate(R.id.widget_queue_list, queueClickTemplate)
                        if (focusQueue) {
                            pendingQueueFocus[appWidgetId] = queueFocus(prefs.getString("queueJson", "[]").orEmpty())
                            // History remains in the adapter, but the scroll
                            // target is the playing row, not its predecessors.
                            setScrollPosition(
                                R.id.widget_queue_list,
                                prefs.getInt("queueCurrentPosition", 0).coerceAtLeast(0),
                            )
                        }
                    }
                }
                setImageViewResource(
                    R.id.widget_play_pause_icon,
                    if (isPlaying) R.drawable.bstream_widget_pause else R.drawable.bstream_widget_play,
                )
                // ProgressBar animates in the launcher while visible. No timer,
                // Dart frames or repeated widget broadcasts drive the spinner.
                setViewVisibility(R.id.widget_play_pause_icon, if (isLoading) View.INVISIBLE else View.VISIBLE)
                setViewVisibility(R.id.widget_play_pause_loading, if (isLoading) View.VISIBLE else View.GONE)
                setContentDescription(
                    R.id.widget_play_pause,
                    if (isLoading) {
                        prefs.getString("loadingLabel", "")?.takeIf { it.isNotBlank() } ?: run {
                            val configuration = Configuration(context.resources.configuration).apply {
                                setLocale(Locale.forLanguageTag(prefs.getString("language", "es") ?: "es"))
                            }
                            context.createConfigurationContext(configuration).getString(R.string.widget_loading)
                        }
                    } else context.getString(R.string.widget_play_pause),
                )
                setInt(
                    R.id.widget_repeat,
                    "setColorFilter",
                    if (repeatMode == "off") Color.WHITE else accent,
                )
                setImageViewResource(
                    R.id.widget_favorite,
                    if (isFavorite) R.drawable.bstream_widget_heart_filled
                    else R.drawable.bstream_widget_heart_outline,
                )
                setInt(
                    R.id.widget_favorite,
                    "setColorFilter",
                    if (isFavorite) accent else Color.WHITE,
                )
                setContentDescription(
                    R.id.widget_repeat,
                    when (repeatMode) {
                        "all" -> context.getString(R.string.widget_repeat_all)
                        "one" -> context.getString(R.string.widget_repeat_one)
                        else -> context.getString(R.string.widget_repeat)
                    },
                )
                val auxiliaryControlVisibility = when {
                    sizeCategory == BStreamWidgetLayout.QUEUE -> View.GONE
                    title.isEmpty() -> View.INVISIBLE
                    else -> View.VISIBLE
                }
                setViewVisibility(R.id.widget_previous, if (title.isEmpty()) View.INVISIBLE else View.VISIBLE)
                setViewVisibility(R.id.widget_repeat, auxiliaryControlVisibility)
                setViewVisibility(R.id.widget_next, if (title.isEmpty()) View.INVISIBLE else View.VISIBLE)
                setViewVisibility(R.id.widget_favorite, auxiliaryControlVisibility)
                setOnClickPendingIntent(R.id.widget_card, openApp(context))
                if (title.isNotEmpty()) {
                    setOnClickPendingIntent(R.id.widget_previous, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PREVIOUS))
                    setOnClickPendingIntent(R.id.widget_repeat, widgetAction(context, "repeat"))
                    setOnClickPendingIntent(R.id.widget_play_pause, mediaButton(context, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
                    setOnClickPendingIntent(R.id.widget_next, mediaButton(context, KeyEvent.KEYCODE_MEDIA_NEXT))
                    setOnClickPendingIntent(R.id.widget_favorite, widgetAction(context, "favorite"))
                } else {
                    setOnClickPendingIntent(R.id.widget_play_pause, openApp(context))
                }
            }
        }

        private fun queueFocus(json: String): String = BStreamWidgetQueue.read(json).focus

        /** Complete a focus request after the launcher has fetched the current row. */
        internal fun onCurrentQueueRowReady(context: Context, widgetId: Int, identity: String) {
            if (!pendingQueueFocus.remove(widgetId, identity)) return
            // One native callback lets the row cross Binder and reach layout.
            // There is no polling, playback-position timer or artwork resend.
            queueFocusHandler.postDelayed({
                val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                if (queueFocus(prefs.getString("queueJson", "[]").orEmpty()) != identity) return@postDelayed
                val manager = AppWidgetManager.getInstance(context)
                val provider = manager.getAppWidgetInfo(widgetId)?.provider ?: return@postDelayed
                if (provider.packageName != context.packageName || provider.className !in widgetProviders) return@postDelayed
                manager.partiallyUpdateAppWidget(
                    widgetId,
                    RemoteViews(context.packageName, R.layout.bstream_music_widget_queue_v2).apply {
                        setScrollPosition(R.id.widget_queue_list, prefs.getInt("queueCurrentPosition", 0).coerceAtLeast(0))
                    },
                )
            }, 160)
        }

        private fun notifyQueueChanged(context: Context, manager: AppWidgetManager, id: Int) {
            val options = manager.getAppWidgetOptions(id)
            val heightOption = if (context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
                AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT
            } else AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT
            val widthOption = if (context.resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
                AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH
            } else AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH
            val height = options.getInt(heightOption, options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 50))
            val width = options.getInt(widthOption, options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 250))
            if (BStreamWidgetLayout.forSize(width, height) == BStreamWidgetLayout.QUEUE) {
                manager.notifyAppWidgetViewDataChanged(id, R.id.widget_queue_list)
            }
        }

        private fun artworkFrame(context: Context, prefs: android.content.SharedPreferences, slot: Int, hasCover: Boolean, accent: Int): ArtworkFrame {
            val file = coverFile(context, slot)
            fun cacheKey(): String = "${file.path}:${file.lastModified()}:${file.length()}:$hasCover:$accent:" +
                "${prefs.getInt("paletteBase$slot", accent)}:${prefs.getInt("paletteHighlight$slot", accent)}"
            val currentKey = cacheKey()
            artworkFrames[slot]?.takeIf { it.key == currentKey }?.let { return it }
            val artwork = if (hasCover && file.isFile) BitmapFactory.decodeFile(file.path) else null
            val palette = if (artwork != null && !prefs.contains("paletteBase$slot")) {
                artworkPalette(artwork).also { colors ->
                    prefs.edit()
                        .putInt("paletteBase$slot", colors.first)
                        .putInt("paletteHighlight$slot", colors.second)
                        .apply()
                }
            } else null
            val base = palette?.first ?: if (artwork != null) prefs.getInt("paletteBase$slot", accent) else accent
            val highlight = palette?.second ?: if (artwork != null) prefs.getInt("paletteHighlight$slot", accent) else accent
            // At most two small cover/backdrop pairs; metadata updates reuse
            // them without decoding files or rebuilding gradients each time.
            return ArtworkFrame(cacheKey(), artwork) { backdrop(base, highlight) }
                .also { artworkFrames[slot] = it }
        }

        private fun bindArtwork(
            context: Context,
            prefs: android.content.SharedPreferences,
            views: RemoteViews,
            accent: Int,
            animateArtwork: Boolean,
            showBackdrop: Boolean,
        ) {
            val hasCover = prefs.getBoolean("hasCover", false)
            val activeSlot = if (hasCover) prefs.getInt("coverSlot", 0).coerceIn(0, 1) else 0
            for (slot in 0..1) {
                val frame = artworkFrame(context, prefs, slot, hasCover, accent)
                val coverId = if (slot == 0) R.id.widget_artwork_first else R.id.widget_artwork_second
                val backdropId = if (slot == 0) R.id.widget_backdrop_first else R.id.widget_backdrop_second
                if (showBackdrop) views.setImageViewBitmap(backdropId, frame.background)
                if (frame.cover != null) {
                    views.setImageViewBitmap(coverId, frame.cover)
                } else {
                    views.setImageViewResource(coverId, R.mipmap.ic_launcher)
                }
                if (!animateArtwork) {
                    val visibility = if (slot == activeSlot) View.VISIBLE else View.GONE
                    views.setViewVisibility(coverId, visibility)
                    if (showBackdrop) views.setViewVisibility(backdropId, visibility)
                }
            }
            // The launcher performs the short native fade; there are no frame
            // timers or repeated bitmap IPC updates in the application.
            if (animateArtwork) {
                views.setDisplayedChild(R.id.widget_artwork, activeSlot)
                if (showBackdrop) views.setDisplayedChild(R.id.widget_backdrop, activeSlot)
            }
        }

        private fun artworkPalette(bitmap: Bitmap): Pair<Int, Int> {
            val totals = LongArray(3)
            val bins = Array(12) { LongArray(4) }
            var samples = 0L
            val hsv = FloatArray(3)
            val stepX = max(1, bitmap.width / 48)
            val stepY = max(1, bitmap.height / 48)
            for (y in 0 until bitmap.height step stepY) {
                for (x in 0 until bitmap.width step stepX) {
                    val color = bitmap.getPixel(x, y)
                    val red = Color.red(color)
                    val green = Color.green(color)
                    val blue = Color.blue(color)
                    totals[0] += red
                    totals[1] += green
                    totals[2] += blue
                    samples++
                    Color.RGBToHSV(red, green, blue, hsv)
                    if (hsv[1] >= 0.18f && hsv[2] >= 0.13f) {
                        val bin = (hsv[0] / 30f).toInt().coerceIn(0, 11)
                        val weight = (1 + hsv[1] * 3).toLong()
                        bins[bin][0] += red * weight
                        bins[bin][1] += green * weight
                        bins[bin][2] += blue * weight
                        bins[bin][3] += weight
                    }
                }
            }
            val average = Color.rgb(
                (totals[0] / samples).toInt(),
                (totals[1] / samples).toInt(),
                (totals[2] / samples).toInt(),
            )
            val dominant = bins.maxByOrNull { it[3] } ?: return average to average
            val vivid = if (dominant[3] > samples / 8) {
                Color.rgb(
                    (dominant[0] / dominant[3]).toInt(),
                    (dominant[1] / dominant[3]).toInt(),
                    (dominant[2] / dominant[3]).toInt(),
                )
            } else average
            return average to vivid
        }

        private fun backdrop(base: Int, highlight: Int): Bitmap {
            // The artwork adds color while the dark gradient keeps text legible.
            val width = 320
            val height = 192
            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
            val canvas = Canvas(bitmap)
            val start = mix(Color.rgb(13, 18, 28), base, 0.56f)
            val end = mix(Color.rgb(8, 12, 19), base, 0.22f)
            val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                shader = LinearGradient(0f, 0f, width.toFloat(), height.toFloat(), start, end, Shader.TileMode.CLAMP)
            }
            canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), paint)
            paint.shader = RadialGradient(
                45f, height * 0.35f, 220f,
                intArrayOf(
                    Color.argb(100, Color.red(highlight), Color.green(highlight), Color.blue(highlight)),
                    Color.TRANSPARENT,
                ),
                null,
                Shader.TileMode.CLAMP,
            )
            canvas.drawCircle(45f, height * 0.35f, 220f, paint)
            return bitmap
        }

        private fun mix(first: Int, second: Int, amount: Float): Int = Color.rgb(
            (Color.red(first) * (1 - amount) + Color.red(second) * amount).toInt().coerceIn(0, 255),
            (Color.green(first) * (1 - amount) + Color.green(second) * amount).toInt().coerceIn(0, 255),
            (Color.blue(first) * (1 - amount) + Color.blue(second) * amount).toInt().coerceIn(0, 255),
        )

        private fun openApp(context: Context): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                action = "com.ryanheise.audioservice.NOTIFICATION_CLICK"
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            return PendingIntent.getActivity(
                context, 8000, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        private fun mediaButton(context: Context, keyCode: Int): PendingIntent {
            return BStreamWidgetPlaybackReceiver.mediaButton(context, keyCode)
        }

        private fun widgetAction(context: Context, action: String): PendingIntent {
            val intent = Intent(context, MainActivity::class.java).apply {
                this.action = MainActivity.ACTION_HOME_WIDGET_CONTROL
                data = Uri.parse("bstreammusic://widget?action=$action")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
                putExtra(MainActivity.EXTRA_HOME_WIDGET_ACTION, action)
            }
            return PendingIntent.getActivity(
                context,
                9000 + action.hashCode(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }
    }
}
