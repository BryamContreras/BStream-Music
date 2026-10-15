package com.bstream.bstream_music

/** Size categories shared by RemoteViews rendering and resizing tests. */
internal enum class BStreamWidgetLayout {
    COMPACT_SMALL, COMPACT, LARGE, EXPANDED;

    val hasSeparateMetadata: Boolean
        get() = this == LARGE || this == EXPANDED

    companion object {
        fun forSize(width: Int, height: Int): BStreamWidgetLayout = when {
            height < 72 -> COMPACT_SMALL
            height < 150 -> COMPACT
            height >= 165 && width >= 340 -> EXPANDED
            else -> LARGE
        }
    }
}
