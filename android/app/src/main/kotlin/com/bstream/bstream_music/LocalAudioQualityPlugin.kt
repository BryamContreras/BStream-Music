package com.bstream.bstream_music

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.DataInputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** One-shot source metadata. No decoder, playback player or periodic observer. */
class LocalAudioQualityPlugin(context: Context, messenger: BinaryMessenger) {
    private val context = context.applicationContext
    private val channel = MethodChannel(messenger, "bstream/local_audio_quality")
    private val mainHandler = Handler(Looper.getMainLooper())
    private val worker = ThreadPoolExecutor(
        1, 1, 0L, TimeUnit.MILLISECONDS, ArrayBlockingQueue<Runnable>(8),
        { task -> Thread(task, "bstream-local-audio-quality").apply { isDaemon = true } },
        ThreadPoolExecutor.AbortPolicy(),
    )
    // Accessed only by the main thread, including completion and disposal.
    private val pending = LinkedHashMap<Long, MethodChannel.Result>()
    private var nextRequestId = 0L
    private var disposed = false

    init { channel.setMethodCallHandler(::handle) }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "read") {
            result.notImplemented()
            return
        }
        val source = call.argument<String>("source")?.trim()
        if (disposed || source == null || !LocalAudioQualityPolicy.allowsSource(source)) {
            result.success(null)
            return
        }
        val requestId = nextRequestId++
        pending[requestId] = result
        try {
            worker.execute {
                val payload = runCatching { read(source) }.getOrNull()
                mainHandler.post { pending.remove(requestId)?.success(payload) }
            }
        } catch (_: RejectedExecutionException) {
            pending.remove(requestId)?.success(null)
        }
    }

    private fun read(source: String): Map<String, Any>? {
        val uri = if (source.startsWith("/")) Uri.fromFile(File(source)) else Uri.parse(source)
        val triedFlacHeader = uri.path?.endsWith(".flac", ignoreCase = true) == true
        if (triedFlacHeader) readFlacHeader(uri)?.let { return it }
        val extractor = MediaExtractor()
        try {
            // Android opens content providers through their existing read grant;
            // no network scheme or new storage permission is accepted here.
            extractor.setDataSource(context, uri, null)
            val count = extractor.trackCount
            var selectedIndex = -1
            var selectedFormat: MediaFormat? = null
            var audioTrackCount = 0
            for (index in 0 until count) {
                val format = extractor.getTrackFormat(index)
                val mime = runCatching { format.getString(MediaFormat.KEY_MIME) }.getOrNull()
                if (mime?.startsWith("audio/", ignoreCase = true) == true) {
                    audioTrackCount++
                    if (selectedIndex < 0) {
                        selectedIndex = index
                        selectedFormat = format
                    }
                }
            }
            if (!LocalAudioQualityPolicy.canDescribeAudioTrack(audioTrackCount)) return null
            val format = selectedFormat ?: return null
            extractor.selectTrack(selectedIndex)
            val mime = format.getString(MediaFormat.KEY_MIME) ?: return null
            val codec = LocalAudioQualityPolicy.codecForMime(mime)
            // Android can expose already-decoded PCM for a FLAC file. Read
            // STREAMINFO to report the original resolution, including for
            // MediaStore content URIs that have no filename in the path.
            if (!triedFlacHeader && (codec == "PCM" || codec == "FLAC")) {
                readFlacHeader(uri)?.let { return it }
            }
            val values = LinkedHashMap<String, Any>()
            values["mimeType"] = mime
            codec?.let { values["codec"] = it }
            positiveNumber(format, MediaFormat.KEY_SAMPLE_RATE)?.let { values["sampleRate"] = it }
            positiveNumber(format, MediaFormat.KEY_CHANNEL_COUNT)?.let { values["channels"] = it }
            val lossless = values["codec"] in setOf("FLAC", "ALAC", "PCM")
            if (lossless) {
                val bitDepth = positiveNumber(format, "bits-per-sample")?.toInt()
                    ?: if (values["codec"] == "FLAC") {
                        LocalAudioQualityPolicy.flacStreamInfo(
                            runCatching { format.getByteBuffer("csd-0") }.getOrNull(),
                        )?.bitDepth
                    } else if (values["codec"] == "PCM") {
                        // Extractor audio/raw describes source PCM. Do not use
                        // a compressed decoder's output encoding as its depth.
                        when (positiveNumber(format, MediaFormat.KEY_PCM_ENCODING)?.toInt()) {
                            android.media.AudioFormat.ENCODING_PCM_8BIT -> 8
                            android.media.AudioFormat.ENCODING_PCM_16BIT -> 16
                            android.media.AudioFormat.ENCODING_PCM_24BIT_PACKED -> 24
                            android.media.AudioFormat.ENCODING_PCM_32BIT,
                            android.media.AudioFormat.ENCODING_PCM_FLOAT -> 32
                            else -> null
                        }
                    } else null
                bitDepth?.takeIf { it in 1..64 }?.let { values["bitDepth"] = it }
            }
            val bitrate = positiveNumber(format, MediaFormat.KEY_BIT_RATE)
                ?: if (LocalAudioQualityPolicy.canUseContainerBitrate(count, audioTrackCount)) {
                    containerBitrate(uri)
                } else null
            bitrate?.let { values["bitrate"] = it }
            return values
        } finally {
            runCatching { extractor.release() }
        }
    }

    private fun readFlacHeader(uri: Uri): Map<String, Any>? = runCatching {
        context.contentResolver.openInputStream(uri)?.let(::DataInputStream)?.use { input ->
            val bytes = ByteArray(42)
            input.readFully(bytes, 0, 4)
            if (bytes[0] == 0x49.toByte() && bytes[1] == 0x44.toByte() && bytes[2] == 0x33.toByte()) {
                input.readFully(bytes, 4, 6)
                var size = 0
                for (index in 6..9) {
                    val part = bytes[index].toInt()
                    if (part < 0) return@use null
                    size = (size shl 7) or part
                }
                if (bytes[5].toInt() and 0x10 != 0) size += 10
                if (size > 16 * 1024 * 1024 || input.skipBytes(size) != size) return@use null
                input.readFully(bytes, 0, 4)
            }
            if (ByteBuffer.wrap(bytes).getInt(0) != 0x664c6143) return@use null
            input.readFully(bytes, 4, 38)
            val info = LocalAudioQualityPolicy.flacStreamInfo(ByteBuffer.wrap(bytes)) ?: return@use null
            mapOf("codec" to "flac", "mimeType" to "audio/flac",
                "bitDepth" to info.bitDepth, "sampleRate" to info.sampleRate, "channels" to info.channels)
        }
    }.getOrNull()

    private fun positiveNumber(format: MediaFormat, key: String): Long? {
        if (!format.containsKey(key)) return null
        val value = runCatching { format.getInteger(key).toLong() }.getOrNull()
            ?: runCatching { format.getLong(key) }.getOrNull()
        return value?.takeIf { it > 0 }
    }

    private fun containerBitrate(uri: Uri): Long? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(context, uri)
            // The extractor already established this is a single audio track;
            // a second check avoids borrowing muxed video bitrate on odd files.
            if (retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_HAS_VIDEO) == "yes") {
                null
            } else {
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)
                    ?.toLongOrNull()?.takeIf { it > 0 }
            }
        } catch (_: Exception) {
            null
        } finally {
            runCatching { retriever.release() }
        }
    }

    fun dispose() {
        if (disposed) return
        disposed = true
        channel.setMethodCallHandler(null)
        pending.values.forEach { it.success(null) }
        pending.clear()
        worker.shutdownNow()
    }
}
