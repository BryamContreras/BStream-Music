package com.bstream.bstream_music

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.text.SpannableString
import android.text.style.StyleSpan
import android.graphics.Typeface
import android.widget.RemoteViews
import android.widget.RemoteViewsService
import java.io.File
import java.util.LinkedHashMap
import org.json.JSONArray

/** Supplies the lightweight, locally cached queue rows for the tall widget. */
class BStreamMusicQueueWidgetService : RemoteViewsService() {
    override fun onGetViewFactory(intent: Intent): RemoteViewsFactory =
        QueueFactory(applicationContext)
}

private class QueueFactory(private val context: Context) : RemoteViewsService.RemoteViewsFactory {
    private data class Entry(
        val id: String,
        val queueIndex: Int,
        val title: String,
        val artist: String,
        val artworkPath: String,
    )

    private var entries: List<Entry> = emptyList()
    private var accent: Int = 0xFF448AFF.toInt()
    private val artworkBitmaps = object : LinkedHashMap<String, Bitmap>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Bitmap>?): Boolean =
            size > 24
    }

    override fun onCreate() = Unit

    override fun onDataSetChanged() {
        val prefs = context.getSharedPreferences("bstream_home_widget", Context.MODE_PRIVATE)
        accent = prefs.getInt("accent", accent)
        entries = runCatching {
            val json = JSONArray(prefs.getString("queueJson", "[]"))
            List(json.length()) { index ->
                val item = json.getJSONObject(index)
                Entry(
                    id = item.optString("id", index.toString()),
                    queueIndex = item.optInt("queueIndex", index),
                    title = item.optString("title").ifBlank { "—" },
                    artist = item.optString("artist"),
                    artworkPath = item.optString("artworkPath"),
                )
            }
        }.getOrDefault(emptyList())
    }

    override fun onDestroy() {
        entries = emptyList()
        artworkBitmaps.clear()
    }

    override fun getCount(): Int = entries.size

    override fun getViewAt(position: Int): RemoteViews? {
        val entry = entries.getOrNull(position) ?: return null
        val views = RemoteViews(context.packageName, R.layout.bstream_music_widget_queue_item)
        val current = position == 0
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
        val artworkPath = entry.artworkPath.takeIf { it.isNotBlank() }
            ?: if (position == 0) currentArtworkPath() else null
        val artwork = artworkPath?.let(::loadQueueArtwork)
        if (artwork != null) {
            views.setImageViewBitmap(R.id.widget_queue_item_artwork, artwork)
        } else {
            views.setImageViewResource(R.id.widget_queue_item_artwork, R.mipmap.ic_launcher)
        }
        views.setViewVisibility(
            R.id.widget_queue_item_current_marker,
            if (current) android.view.View.VISIBLE else android.view.View.GONE,
        )
        if (current) {
            views.setInt(R.id.widget_queue_item_current_marker, "setBackgroundColor", accent)
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
        return views
    }

    private fun loadQueueArtwork(path: String): Bitmap? {
        artworkBitmaps[path]?.let { return it }
        val file = File(path)
        if (!file.isFile) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(path, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (bounds.outWidth / sample > 96 || bounds.outHeight / sample > 96) {
            sample *= 2
        }
        val bitmap = BitmapFactory.decodeFile(
            path,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: return null
        artworkBitmaps[path] = bitmap
        return bitmap
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
        val entry = entries.getOrNull(position) ?: return position.toLong()
        return (entry.id.hashCode().toLong() shl 32) xor position.toLong()
    }

    override fun hasStableIds(): Boolean = true
}
