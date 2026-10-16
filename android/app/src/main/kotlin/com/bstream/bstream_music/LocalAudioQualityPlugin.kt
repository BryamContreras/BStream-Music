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
import java.io.File
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
            val values = LinkedHashMap<String, Any>()
            values["mimeType"] = mime
            LocalAudioQualityPolicy.codecForMime(mime)?.let { values["codec"] = it }
            positiveNumber(format, MediaFormat.KEY_SAMPLE_RATE)?.let { values["sampleRate"] = it }
            positiveNumber(format, MediaFormat.KEY_CHANNEL_COUNT)?.let { values["channels"] = it }
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
