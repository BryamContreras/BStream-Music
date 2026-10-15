package com.bstream.bstream_music

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class BStreamWidgetLayoutTest {
    @Test
    fun compactSizesRetainTheirExistingLayout() {
        for (width in listOf(250, 339, 340, 430)) {
            assertEquals(BStreamWidgetLayout.COMPACT_SMALL, BStreamWidgetLayout.forSize(width, 56))
            assertEquals(BStreamWidgetLayout.COMPACT_SMALL, BStreamWidgetLayout.forSize(width, 71))
            assertEquals(BStreamWidgetLayout.COMPACT, BStreamWidgetLayout.forSize(width, 72))
            assertEquals(BStreamWidgetLayout.COMPACT, BStreamWidgetLayout.forSize(width, 149))
        }
    }

    @Test
    fun tallWidgetsUseSeparateMetadataEvenWhenNarrow() {
        assertEquals(BStreamWidgetLayout.LARGE, BStreamWidgetLayout.forSize(250, 150))
        assertEquals(BStreamWidgetLayout.LARGE, BStreamWidgetLayout.forSize(430, 164))
        assertEquals(BStreamWidgetLayout.LARGE, BStreamWidgetLayout.forSize(339, 165))
        assertEquals(BStreamWidgetLayout.LARGE, BStreamWidgetLayout.forSize(250, 320))
        assertEquals(BStreamWidgetLayout.EXPANDED, BStreamWidgetLayout.forSize(340, 165))
        assertEquals(BStreamWidgetLayout.EXPANDED, BStreamWidgetLayout.forSize(430, 320))
    }

    @Test
    fun onlyLargeVariantsShowThreeMetadataLines() {
        assertFalse(BStreamWidgetLayout.COMPACT_SMALL.hasSeparateMetadata)
        assertFalse(BStreamWidgetLayout.COMPACT.hasSeparateMetadata)
        assertTrue(BStreamWidgetLayout.LARGE.hasSeparateMetadata)
        assertTrue(BStreamWidgetLayout.EXPANDED.hasSeparateMetadata)
    }
}
