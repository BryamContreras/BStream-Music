package com.bstream.bstream_music

/** Size categories shared by RemoteViews rendering and resizing tests. */
internal enum class BStreamWidgetLayout {
    COMPACT_SMALL, COMPACT, LARGE, EXPANDED, QUEUE;

    val hasSeparateMetadata: Boolean
        get() = this == LARGE || this == EXPANDED || this == QUEUE

    companion object {
        fun forSize(width: Int, height: Int): BStreamWidgetLayout = when {
            height < 72 -> COMPACT_SMALL
            height < 150 -> COMPACT
            // Samsung reports 220dp for a two-row widget. Keep the queue
            // layout for genuinely taller (three-row) widgets only.
            height >= 250 && width >= 340 -> QUEUE
            height >= 165 && width >= 340 -> EXPANDED
            else -> LARGE
        }
    }
}
