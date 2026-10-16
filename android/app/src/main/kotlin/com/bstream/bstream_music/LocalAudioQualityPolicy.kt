package com.bstream.bstream_music

import java.net.URI
import java.util.Locale

/** Pure input/format policy shared by the channel and inexpensive JVM tests. */
internal object LocalAudioQualityPolicy {
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
