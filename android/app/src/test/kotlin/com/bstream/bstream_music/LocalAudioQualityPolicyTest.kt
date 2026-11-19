package com.bstream.bstream_music

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LocalAudioQualityPolicyTest {
    @Test fun readsOriginalFlacPrecisionWithoutChangingTheCodecBuffer() {
        for (depth in listOf(16, 20, 24, 32)) {
            val header = java.nio.ByteBuffer.allocate(42)
                .putInt(0x664c6143).putInt(34)
            header.putLong(18, (96000L shl 44) or (1L shl 41) or ((depth - 1L) shl 36))
            header.position(0)
            val expected = LocalAudioQualityPolicy.FlacStreamInfo(depth, 96000, 2)
            assertEquals(expected, LocalAudioQualityPolicy.flacStreamInfo(header))
            assertEquals(0, header.position())
            val streamInfo = header.duplicate().apply { position(8) }.slice()
            assertEquals(expected, LocalAudioQualityPolicy.flacStreamInfo(streamInfo))
        }
        assertNull(LocalAudioQualityPolicy.flacStreamInfo(null))
        assertNull(LocalAudioQualityPolicy.flacStreamInfo(java.nio.ByteBuffer.allocate(8)))
    }
    @Test fun acceptsOnlyAccessibleLocalSourceKinds() {
        listOf("/storage/emulated/0/Music/song.mp3", "file:///data/user/0/app/song%20name.m4a",
            "file://localhost/storage/song.flac", "content://media/external/audio/media/12")
            .forEach { assertTrue(LocalAudioQualityPolicy.allowsSource(it), it) }
        listOf("", "song.mp3", "https://example.com/song.mp3", "http://127.0.0.1/music",
            "ftp://host/song", "data:audio/aac;base64,AA", "file://remote-host/song.mp3",
            "file:relative.mp3", "content:///missing-authority", "/music/bad\u0000song.mp3")
            .forEach { assertFalse(LocalAudioQualityPolicy.allowsSource(it), it) }
    }

    @Test fun reportsCodecFromAudioMimeInsteadOfContainerOrDecodedOutput() {
        assertEquals("AAC", LocalAudioQualityPolicy.codecForMime("audio/mp4a-latm"))
        assertEquals("Opus", LocalAudioQualityPolicy.codecForMime("audio/opus"))
        assertEquals("MP3", LocalAudioQualityPolicy.codecForMime("audio/mpeg"))
        assertEquals("FLAC", LocalAudioQualityPolicy.codecForMime("audio/flac"))
        assertEquals("ALAC", LocalAudioQualityPolicy.codecForMime("audio/alac"))
        assertEquals("PCM", LocalAudioQualityPolicy.codecForMime("audio/raw"))
        assertNull(LocalAudioQualityPolicy.codecForMime("audio/unknown-codec"))
        assertNull(LocalAudioQualityPolicy.codecForMime("video/mp4"))
    }

    @Test fun neverUsesWholeContainerBitrateForMuxedOrMultipleAudioTracks() {
        assertTrue(LocalAudioQualityPolicy.canUseContainerBitrate(1, 1))
        assertFalse(LocalAudioQualityPolicy.canUseContainerBitrate(2, 1))
        assertFalse(LocalAudioQualityPolicy.canUseContainerBitrate(2, 2))
        assertFalse(LocalAudioQualityPolicy.canUseContainerBitrate(0, 0))
    }

    @Test fun neverAssumesTheFirstAlternateAudioTrackIsPlaying() {
        assertTrue(LocalAudioQualityPolicy.canDescribeAudioTrack(1))
        assertFalse(LocalAudioQualityPolicy.canDescribeAudioTrack(0))
        assertFalse(LocalAudioQualityPolicy.canDescribeAudioTrack(2))
        assertFalse(LocalAudioQualityPolicy.canDescribeAudioTrack(3))
    }
}
