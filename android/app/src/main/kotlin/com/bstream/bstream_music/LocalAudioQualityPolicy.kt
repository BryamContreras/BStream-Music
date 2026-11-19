package com.bstream.bstream_music

import java.net.URI
import java.util.Locale
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Pure input/format policy shared by the channel and inexpensive JVM tests. */
internal object LocalAudioQualityPolicy {
    data class FlacStreamInfo(val bitDepth: Int, val sampleRate: Int, val channels: Int)

    fun flacStreamInfo(data: ByteBuffer?): FlacStreamInfo? {
        val bytes = data?.duplicate()?.order(ByteOrder.BIG_ENDIAN) ?: return null
        val start = bytes.position()
        val packedOffset = when {
            bytes.remaining() == 34 -> start + 10
            bytes.remaining() >= 42 && bytes.getInt(start) == 0x664c6143 &&
                (bytes.get(start + 4).toInt() and 0x7f) == 0 &&
                bytes.get(start + 5).toInt() == 0 && bytes.get(start + 6).toInt() == 0 &&
                bytes.get(start + 7).toInt() == 34 -> start + 18
            else -> return null
        }
        val packed = bytes.getLong(packedOffset)
        val bitDepth = (((packed ushr 36) and 31) + 1).toInt()
        val sampleRate = ((packed ushr 44) and 0xfffff).toInt()
        val channels = (((packed ushr 41) and 7) + 1).toInt()
        return if (bitDepth in 4..32 && sampleRate > 0) {
            FlacStreamInfo(bitDepth, sampleRate, channels)
        } else null
    }

    fun allowsSource(source: String): Boolean {
        val value = source.trim()
        if (value.isEmpty() || value.indexOf('\u0000') >= 0) return false
        if (value.startsWith("/")) return true
        val uri = runCatching { URI(value) }.getOrNull() ?: return false
        return when (uri.scheme?.lowercase(Locale.ROOT)) {
            "content" -> !uri.rawAuthority.isNullOrBlank()
            "file" -> (uri.host.isNullOrEmpty() || uri.host.equals("localhost", true)) &&
                uri.path?.startsWith("/") == true && uri.rawQuery == null && uri.rawFragment == null
            else -> false
        }
    }

    fun codecForMime(mimeType: String): String? = when (mimeType.lowercase(Locale.ROOT)) {
        "audio/mp4a-latm", "audio/aac", "audio/x-aac", "audio/aac-adts" -> "AAC"
        "audio/opus" -> "Opus"
        "audio/mpeg", "audio/mp3", "audio/mpeg-l3" -> "MP3"
        "audio/flac", "audio/x-flac" -> "FLAC"
        "audio/raw", "audio/pcm", "audio/x-pcm" -> "PCM"
        "audio/alac", "audio/x-alac" -> "ALAC"
        "audio/vorbis" -> "Vorbis"
        "audio/ac3" -> "AC-3"
        "audio/eac3", "audio/eac3-joc" -> "E-AC-3"
        "audio/3gpp", "audio/amr", "audio/amr-nb" -> "AMR"
        "audio/amr-wb" -> "AMR-WB"
        else -> null
    }

    // Retriever bitrate is for the entire container. It is not an audio
    // bitrate if a video, alternate audio or other track contributes bytes.
    fun canUseContainerBitrate(trackCount: Int, audioTrackCount: Int): Boolean =
        trackCount == 1 && audioTrackCount == 1

    // We do not know which alternate audio track the playback backend chose.
    fun canDescribeAudioTrack(audioTrackCount: Int): Boolean = audioTrackCount == 1
}
