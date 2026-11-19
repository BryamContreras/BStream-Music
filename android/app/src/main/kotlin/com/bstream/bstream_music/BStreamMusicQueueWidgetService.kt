package com.bstream.bstream_music

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.text.SpannableString
import android.text.style.StyleSpan
import android.graphics.Typeface
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import java.io.File
import java.util.LinkedHashMap
import kotlin.math.roundToInt
import org.json.JSONArray

/** Supplies the lightweight, locally cached queue rows for the tall widget. */
class BStreamMusicQueueWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        QueueFactory(applicationContext, intent.getIntExtra(
            AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID,
        ))
}

internal object BStreamWidgetQueue {
    data class Entry(
        val id: String,
        val queueIndex: Int,
        val title: String,
        val artist: String,
        val artworkPath: String,
        val isCurrent: Boolean,
    )

    data class Snapshot(
        val entries: List<Entry>,
        val selectedPosition: Int?,
        val focus: String,
    )

    val empty = Snapshot(emptyList(), null, ":")
    private var cachedJson = "[]"
    private var cachedSnapshot = empty

    @Synchronized
    fun read(json: String): Snapshot {
        if (json == cachedJson) return cachedSnapshot
        val snapshot = runCatching {
            val array = JSONArray(json)
            var selectedPosition: Int? = null
            val entries = (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                val isCurrent = item.optBoolean("isCurrent", false)
                if (isCurrent && selectedPosition == null) selectedPosition = index
                Entry(
                    id = item.optString("id", index.toString()),
                    queueIndex = item.optInt("queueIndex", index),
                    title = item.optString("title").ifBlank { "—" },
                    artist = item.optString("artist"),
                    artworkPath = item.optString("artworkPath"),
                    isCurrent = isCurrent,
                )
            }
            val current = array.optJSONObject(selectedPosition ?: 0)
            Snapshot(
                entries.takeIf { it.size == array.length() }.orEmpty(),
                selectedPosition,
                "${current?.optString("queueIndex").orEmpty()}:${current?.optString("id").orEmpty()}",
            )
        }.getOrElse { empty.copy(focus = "") }
        cachedJson = json
        cachedSnapshot = snapshot
        return snapshot
    }
}

internal class QueueFactory(
    private val context: Context,
    private val widgetId: Int = AppWidgetManager.INVALID_APPWIDGET_ID,
) : RemoteViewsService.RemoteViewsFactory {
    private data class ArtworkKey(
        val path: String,
        val modifiedAt: Long,
        val length: Long,
        val size: Int,
    )

    companion object {
        private val artworkBitmaps = object : LinkedHashMap<ArtworkKey, Bitmap>(16, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<ArtworkKey, Bitmap>?): Boolean =
                size > 24
        }
    }

    private var queue = BStreamWidgetQueue.empty
    private var accent: Int = 0xFF448AFF.toInt()

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        val prefs = context.getSharedPreferences("bstream_home_widget", Context.MODE_PRIVATE)
        accent = prefs.getInt("accent", accent)
        queue = BStreamWidgetQueue.read(prefs.getString("queueJson", "[]").orEmpty())
    }

    override fun onDestroy() {
        queue = BStreamWidgetQueue.empty
    }

    override fun getCount(): Int = queue.entries.size

    override fun getViewAt(position: Int): RemoteViews? {
        val snapshot = queue
        val entry = snapshot.entries.getOrNull(position) ?: return null
        val views = RemoteViews(context.packageName, R.layout.bstream_music_widget_queue_item)
        val current = entry.isCurrent || (snapshot.selectedPosition == null && position == 0)
        val styledTitle = SpannableString(entry.title)
        if (current && entry.title.isNotEmpty()) {
            styledTitle.setSpan(StyleSpan(Typeface.BOLD), 0, entry.title.length, 0)
        }
        views.setTextViewText(R.id.widget_queue_item_title, styledTitle)
        views.setTextViewText(R.id.widget_queue_item_artist, entry.artist)
        views.setTextColor(
            R.id.widget_queue_item_title,
            if (current) accent else 0xD7DDE3E8.toInt(),
        )
        views.setTextColor(
            R.id.widget_queue_item_artist,
            if (current) 0xE0FFFFFF.toInt() else 0xBFC5CCD3.toInt(),
        )
        if (current) {
            views.setInt(
                R.id.widget_queue_item_root,
                "setBackgroundResource",
                R.drawable.bstream_widget_queue_item_current,
            )
        } else {
            views.setInt(R.id.widget_queue_item_root, "setBackgroundColor", 0x00000000)
        }
        views.setViewVisibility(
            R.id.widget_queue_item_playing_indicator,
            if (current) android.view.View.VISIBLE else android.view.View.GONE,
        )
        if (current) {
            views.setInt(R.id.widget_queue_item_playing_indicator, "setColorFilter", accent)
        }
        val artworkPath = entry.artworkPath.takeIf { it.isNotBlank() }
            ?: if (current) currentArtworkPath() else null
        val artwork = artworkPath?.let(::loadQueueArtwork)
        if (artwork != null) {
            views.setImageViewBitmap(R.id.widget_queue_item_artwork, artwork)
        } else {
            views.setImageViewResource(R.id.widget_queue_item_artwork, R.mipmap.ic_launcher)
        }
        val fillInIntent = Intent().putExtra(
            MainActivity.EXTRA_HOME_WIDGET_ACTION,
            "queue:${entry.queueIndex}",
        )
        listOf(
            R.id.widget_queue_item_root,
            R.id.widget_queue_item_artwork,
            R.id.widget_queue_item_title,
            R.id.widget_queue_item_artist,
        ).forEach { viewId -> views.setOnClickFillInIntent(viewId, fillInIntent) }
        if (current && widgetId != AppWidgetManager.INVALID_APPWIDGET_ID) {
            BStreamMusicWidget.onCurrentQueueRowReady(context, widgetId, "${entry.queueIndex}:${entry.id}")
        }
        return views
    }

    internal fun loadQueueArtwork(path: String): Bitmap? {
        val file = File(path)
        if (!file.isFile) return null
        val targetSize = (52 * context.resources.displayMetrics.density).roundToInt()
            .coerceIn(52, 256)
        val key = ArtworkKey(path, file.lastModified(), file.length(), targetSize)
        return synchronized(artworkBitmaps) {
            artworkBitmaps[key] ?: BStreamWidgetArtwork.decode(file, targetSize)?.also {
                artworkBitmaps[key] = it
            }
        }
    }

    private fun currentArtworkPath(): String? {
        val prefs = context.getSharedPreferences("bstream_home_widget", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("hasCover", false)) return null
        val slot = prefs.getInt("coverSlot", 0).coerceIn(0, 1)
        val file = File(
            context.filesDir,
            if (slot == 0) "bstream_widget_cover.jpg" else "bstream_widget_cover_alternate.jpg",
        )
        return file.path.takeIf { file.isFile }
    }

    override fun getLoadingView(): RemoteViews? = null

    override fun getViewTypeCount(): Int = 1

    override fun getItemId(position: Int): Long {
        val entry = queue.entries.getOrNull(position) ?: return position.toLong()
        return (entry.id.hashCode().toLong() shl 32) xor position.toLong()
    }

    override fun hasStableIds(): Boolean = true
}
