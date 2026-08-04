package com.bstream.bstream_music

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : AudioServiceActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val updateLock = Object()
    private var progressSink: EventChannel.EventSink? = null
    private var youtubeDlInitialized = false
    private var updateRunning = false
    private var updateCompleted = false
    private val progressEmissionLock = Object()
    private val progressEmissions = mutableMapOf<String, ProgressEmission>()
    private var pendingFileExportResult: MethodChannel.Result? = null
    private var pendingFileExportSourcePath: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionIfNeeded()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initYtdl" -> initYtdl(result)
                "getInfo" -> getInfo(call, result)
                "getPlaybackInfo" -> getPlaybackInfo(call, result)
                "search" -> search(call, result)
                "downloadAudio" -> downloadAudio(call, result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_EXPORT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "saveFile" -> saveFile(call, result)
                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PROGRESS_CHANNEL,
        ).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    progressSink = events
                }

                override fun onCancel(arguments: Any?) {
                    progressSink = null
                }
            },
        )
    }

    private fun saveFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingFileExportResult != null) {
            result.error("export_busy", "Ya hay una exportacion en curso.", null)
            return
        }

        val sourcePath = call.requiredString("sourcePath")
        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) {
            result.error("export_missing", "No se encontro el archivo para exportar.", null)
            return
        }

        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = call.argument<String>("mimeType") ?: "application/zip"
            putExtra(Intent.EXTRA_TITLE, call.argument<String>("fileName") ?: source.name)
        }
        pendingFileExportResult = result
        pendingFileExportSourcePath = sourcePath
        try {
            startActivityForResult(intent, FILE_EXPORT_REQUEST)
        } catch (error: Throwable) {
            clearPendingFileExport()
            result.error("export_start_failed", error.message, error.stackTraceToString())
        }
    }

    @Deprecated("Deprecated in the Android framework, required by the document picker callback")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != FILE_EXPORT_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingFileExportResult ?: return
        val sourcePath = pendingFileExportSourcePath
        if (resultCode != Activity.RESULT_OK) {
            clearPendingFileExport()
            result.success(null)
            return
        }
        val destination = data?.data
        if (sourcePath == null || destination == null) {
            clearPendingFileExport()
            result.error("export_destination_missing", "No se obtuvo el destino del respaldo.", null)
            return
        }

        thread(name = "BStreamBackupExport") {
            try {
                File(sourcePath).inputStream().buffered().use { input ->
                    val output = contentResolver.openOutputStream(destination, "w")
                        ?: throw IllegalStateException("No se pudo abrir el destino del respaldo.")
                    output.buffered().use { input.copyTo(it, DEFAULT_BUFFER_SIZE) }
                }
                mainHandler.post {
                    clearPendingFileExport()
                    result.success(destination.toString())
                }
            } catch (error: Throwable) {
                mainHandler.post {
                    clearPendingFileExport()
                    result.error("export_failed", error.message, error.stackTraceToString())
                }
            }
        }
    }

    private fun clearPendingFileExport() {
        pendingFileExportResult = null
        pendingFileExportSourcePath = null
    }

    private fun initYtdl(result: MethodChannel.Result) {
        runAsync(result) {
            ensureYoutubeDlInitialized()
            true
        }
    }

    private fun getInfo(call: MethodCall, result: MethodChannel.Result) {
        val url = call.requiredString("url")
        runAsync(result) {
            ensureYoutubeDlInitialized()
            executeInfoRequest(url)
        }
    }

    private fun getPlaybackInfo(call: MethodCall, result: MethodChannel.Result) {
        val url = call.requiredString("url")
        runAsync(result) {
            ensureYoutubeDlInitialized()
            executePlaybackInfoRequest(url)
        }
    }

    private fun search(call: MethodCall, result: MethodChannel.Result) {
        val query = call.requiredString("query")
        runAsync(result) {
            ensureYoutubeDlInitialized()
            executeSearchRequest(query)
        }
    }

    private fun executeInfoRequest(url: String): Map<String, Any?> {
        return executeWithExtractorRetry("getInfo") {
            val request = YoutubeDLRequest(url)
            addBaseNetworkOptions(request)
            request.addOption("--dump-single-json")
            request.addOption("--no-playlist")
            request.addOption("-f", AUDIO_FORMAT_SELECTOR)
            val response = YoutubeDL.getInstance().execute(request)
            JSONObject(response.out).toMap()
        }
    }

    private fun executePlaybackInfoRequest(url: String): Map<String, Any?> {
        return executeWithExtractorRetry("getPlaybackInfo") {
            val startedAt = SystemClock.elapsedRealtime()
            val request = YoutubeDLRequest(url)
            addBaseNetworkOptions(request)
            request.addOption("--dump-single-json")
            request.addOption("--skip-download")
            request.addOption("--no-playlist")
            request.addOption("-f", AUDIO_FORMAT_SELECTOR)
            val response = YoutubeDL.getInstance().execute(request)
            Log.i(
                TAG,
                "getPlaybackInfo JSON completed in ${SystemClock.elapsedRealtime() - startedAt}ms",
            )
            val info = JSONObject(response.out)
            val selectedFormat = selectedPlaybackFormat(info)
            val streamUrl = selectedFormat.nonBlankString("url")
                ?: throw IllegalStateException("No se encontro una URL reproducible.")
            val httpHeaders = (
                selectedFormat.optJSONObject("http_headers")
                    ?: info.optJSONObject("http_headers")
                )?.toMap()
            val semanticTitle = info.nonBlankString("track")
                ?: info.nonBlankString("title")
            mapOf(
                "id" to info.nonBlankString("id"),
                "title" to semanticTitle,
                "track" to info.nonBlankString("track"),
                "artist" to info.nonBlankString("artist"),
                "artists" to (
                    info.optJSONArray("artists")?.toList()
                        ?: info.nonBlankString("artists")
                    ),
                "creator" to info.nonBlankString("creator"),
                "uploader" to info.nonBlankString("uploader"),
                "channel" to info.nonBlankString("channel"),
                "webpage_url" to (info.nonBlankString("webpage_url") ?: url),
                "original_url" to (info.nonBlankString("original_url") ?: url),
                "url" to url,
                "streamUrl" to streamUrl,
                "thumbnail" to info.nonBlankString("thumbnail"),
                "duration" to info.opt("duration").takeUnless { it == JSONObject.NULL },
                "extractor" to info.nonBlankString("extractor"),
                "extractor_key" to info.nonBlankString("extractor_key"),
                "album" to info.nonBlankString("album"),
                "view_count" to info.opt("view_count").takeUnless { it == JSONObject.NULL },
                "http_headers" to httpHeaders,
            )
        }
    }

    private fun selectedPlaybackFormat(info: JSONObject): JSONObject {
        for (key in listOf("requested_downloads", "requested_formats")) {
            val formats = info.optJSONArray(key) ?: continue
            for (index in 0 until formats.length()) {
                val format = formats.optJSONObject(index) ?: continue
                if (format.nonBlankString("url")?.startsWith("http") == true) {
                    return format
                }
            }
        }

        if (info.nonBlankString("url")?.startsWith("http") == true) {
            return info
        }
        return info
    }

    private fun JSONObject.nonBlankString(key: String): String? {
        val value = opt(key)
        if (value == null || value == JSONObject.NULL) {
            return null
        }
        return value.toString().trim().takeIf { it.isNotEmpty() }
    }

    private fun executeSearchRequest(query: String): List<Map<String, Any?>> {
        return executeWithExtractorRetry("search") {
            val request = YoutubeDLRequest("ytsearch10:$query")
            addBaseNetworkOptions(request)
            request.addOption("--dump-json")
            request.addOption("--flat-playlist")
            val response = YoutubeDL.getInstance().execute(request)
            response.out
                .lineSequence()
                .filter { it.isNotBlank() }
                .map { JSONObject(it).toMap() }
                .toList()
        }
    }

    private fun downloadAudio(call: MethodCall, result: MethodChannel.Result) {
        val url = call.requiredString("url")
        val path = call.requiredString("path")
        val restrictFileNames = call.argument<Boolean>("restrictFileNames") ?: true

        runAsync(result) {
            ensureYoutubeDlInitialized()
            executeAudioDownload(
                call = call,
                url = url,
                path = path,
                restrictFileNames = restrictFileNames,
            )
        }
    }

    private fun executeAudioDownload(
        call: MethodCall,
        url: String,
        path: String,
        restrictFileNames: Boolean,
    ): Map<String, Any?> {
        val eventTaskId = call.argument<String>("taskId")
            ?.takeIf { it.isNotBlank() }
            ?: UUID.randomUUID().toString()
        return executeWithExtractorRetry(
            operation = "downloadAudio",
            onRetry = {
                emitProgress(
                    eventTaskId,
                    url,
                    "running",
                    0.03f,
                    "Actualizando yt-dlp y reintentando",
                    null,
                )
            },
        ) {
            executeDownload(
                audioDownloadRequest(
                    call = call,
                    url = url,
                    path = path,
                    restrictFileNames = restrictFileNames,
                ),
                url,
                path,
                eventTaskId,
            )
        }
    }

    private fun audioDownloadRequest(
        call: MethodCall,
        url: String,
        path: String,
        restrictFileNames: Boolean,
    ): YoutubeDLRequest {
        val request = baseDownloadRequest(call, url, path, restrictFileNames)
        request.addOption("-f", AUDIO_FORMAT_SELECTOR)
        return request
    }

    private fun baseDownloadRequest(
        call: MethodCall,
        url: String,
        path: String,
        restrictFileNames: Boolean,
    ): YoutubeDLRequest {
        File(path).mkdirs()
        val request = YoutubeDLRequest(url)
        val fileName = call.argument<String>("fileName")
        val templateName = if (fileName.isNullOrBlank()) {
            "%(uploader,channel,artist|BStream)s - %(title)s.%(ext)s"
        } else {
            "$fileName.%(ext)s"
        }
        request.addOption("--newline")
        request.addOption("--no-playlist")
        request.addOption("--fixup", "never")
        request.addOption("--downloader", "native")
        addBaseNetworkOptions(request)
        request.addOption("--progress")
        request.addOption("--progress-template", PROGRESS_TEMPLATE)
        request.addOption("--progress-delta", "0.2")
        request.addOption("--print", "after_move:filepath")
        if (restrictFileNames) {
            request.addOption("--restrict-filenames")
        }
        request.addOption("-o", File(path, templateName).absolutePath)
        return request
    }

    private fun executeDownload(
        request: YoutubeDLRequest,
        url: String,
        path: String,
        eventTaskId: String,
    ): Map<String, Any?> {
        val executionTaskId = UUID.randomUUID().toString()
        emitProgress(eventTaskId, url, "queued", 0f, "Preparando descarga", null)

        val response = YoutubeDL.getInstance().execute(request, executionTaskId) { progress, eta, line ->
            val parsed = parseDownloadProgressLine(line)
            val normalizedProgress = parsed?.progress ?: if (progress in 0f..100f) {
                (progress / 100f).coerceAtMost(0.98f)
            } else {
                null
            }
            val etaSeconds = parsed?.etaSeconds ?: eta.takeIf { it >= 0L }
            val message = normalizedProgress?.let {
                "Descargando ${String.format("%.1f", it * 100f)}%"
            } ?: line
            emitProgress(eventTaskId, url, "running", normalizedProgress, message, etaSeconds)
            Unit
        }

        val filePath = response.out
            .lineSequence()
            .map { it.trim() }
            .lastOrNull { isExistingDownloadedFile(it) }
            ?: newestAudioFile(path)
            ?: throw IllegalStateException("La descarga termino sin un archivo de audio valido.")

        emitProgress(eventTaskId, url, "completed", 1f, "Descarga completada", null)
        return mapOf("filePath" to filePath)
    }

    private fun parseDownloadProgressLine(line: String): DownloadProgressSample? {
        val structured = STRUCTURED_PROGRESS_REGEX.find(line)
        if (structured != null) {
            val rawProgress = structured.groupValues[1].toFloatOrNull() ?: return null
            val rawEta = structured.groupValues[2].trim()
            val etaSeconds = rawEta.toDoubleOrNull()
                ?.takeIf { it.isFinite() && it >= 0.0 }
                ?.toLong()
            return DownloadProgressSample(
                progress = (rawProgress / 100f).coerceIn(0f, 0.98f),
                etaSeconds = etaSeconds,
            )
        }

        val standard = STANDARD_PROGRESS_REGEX.find(line) ?: return null
        val rawProgress = standard.groupValues[1].toFloatOrNull() ?: return null
        val etaSeconds = STANDARD_ETA_REGEX.find(line)
            ?.groupValues
            ?.get(1)
            ?.let(::parseEtaSeconds)
        return DownloadProgressSample(
            progress = (rawProgress / 100f).coerceIn(0f, 0.98f),
            etaSeconds = etaSeconds,
        )
    }

    private fun parseEtaSeconds(value: String): Long? {
        val parts = value.split(':').map { it.toLongOrNull() }
        if (parts.any { it == null }) {
            return null
        }
        return when (parts.size) {
            2 -> parts[0]!! * 60L + parts[1]!!
            3 -> parts[0]!! * 3600L + parts[1]!! * 60L + parts[2]!!
            else -> null
        }
    }

    private fun newestAudioFile(path: String): String? {
        return File(path)
            .listFiles()
            ?.filter { it.isFile && isAudioExtension(it.extension) }
            ?.maxByOrNull { it.lastModified() }
            ?.absolutePath
    }

    private fun isExistingDownloadedFile(path: String): Boolean {
        if (path.isBlank()) {
            return false
        }
        val file = File(path)
        return file.exists() && file.isFile
    }

    private fun isAudioExtension(extension: String): Boolean {
        return AUDIO_EXTENSIONS.contains(extension.lowercase())
    }

    @Synchronized
    private fun ensureYoutubeDlInitialized() {
        if (youtubeDlInitialized) {
            return
        }
        YoutubeDL.getInstance().init(applicationContext)
        youtubeDlInitialized = true
    }

    private fun updateYoutubeDlBlocking(): Boolean {
        synchronized(updateLock) {
            if (updateCompleted) {
                return true
            }
            while (updateRunning) {
                updateLock.wait()
                if (updateCompleted) {
                    return true
                }
            }
            updateRunning = true
        }

        return try {
            val status = YoutubeDL.getInstance()
                .updateYoutubeDL(applicationContext, YoutubeDL.UpdateChannel.NIGHTLY)
            Log.i(TAG, "yt-dlp update status: $status")
            synchronized(updateLock) {
                updateCompleted = true
            }
            true
        } catch (error: Throwable) {
            Log.w(TAG, "No se pudo actualizar yt-dlp", error)
            false
        } finally {
            synchronized(updateLock) {
                updateRunning = false
                updateLock.notifyAll()
            }
        }
    }

    private fun addBaseNetworkOptions(request: YoutubeDLRequest) {
        request.addOption("--ignore-config")
        request.addOption("--no-warnings")
        request.addOption("--socket-timeout", "20")
    }

    private fun <T> executeWithExtractorRetry(
        operation: String,
        onRetry: (() -> Unit)? = null,
        block: () -> T,
    ): T {
        return try {
            block()
        } catch (error: Exception) {
            if (!shouldRetryAfterExtractorUpdate(error)) {
                throw error
            }
            Log.w(TAG, "Retrying $operation after yt-dlp update", error)
            onRetry?.invoke()
            if (!updateYoutubeDlBlocking()) {
                throw error
            }
            try {
                block()
            } catch (retryError: Exception) {
                retryError.addSuppressed(error)
                throw retryError
            }
        }
    }

    private fun shouldRetryAfterExtractorUpdate(error: Throwable): Boolean {
        val details = generateSequence(error) { it.cause }
            .take(6)
            .joinToString(" ") { it.message.orEmpty() }
            .lowercase()

        if (DEFINITIVE_EXTRACTION_ERRORS.any(details::contains)) {
            return false
        }
        return RECOVERABLE_EXTRACTOR_ERRORS.any(details::contains)
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    private fun emitProgress(
        taskId: String,
        url: String,
        status: String,
        progress: Float?,
        message: String?,
        etaSeconds: Long?,
    ) {
        if (!shouldEmitProgress(taskId, status, progress)) {
            return
        }
        val payload = mapOf(
            "taskId" to taskId,
            "url" to url,
            "status" to status,
            "progress" to progress,
            "message" to message,
            "etaSeconds" to etaSeconds,
        )
        mainHandler.post {
            progressSink?.success(payload)
        }
    }

    private fun shouldEmitProgress(taskId: String, status: String, progress: Float?): Boolean {
        val now = SystemClock.elapsedRealtime()
        synchronized(progressEmissionLock) {
            val previous = progressEmissions[taskId]
            val terminal = status == "completed" || status == "failed"
            if (status == "running" && previous?.status == "running") {
                val elapsed = now - previous.emittedAt
                val delta = if (progress != null && previous.progress != null) {
                    kotlin.math.abs(progress - previous.progress)
                } else {
                    0f
                }
                if (elapsed < PROGRESS_MIN_INTERVAL_MS && delta < PROGRESS_MIN_DELTA) {
                    return false
                }
            }

            if (terminal) {
                progressEmissions.remove(taskId)
            } else {
                progressEmissions[taskId] = ProgressEmission(now, progress, status)
            }
            return true
        }
    }

    private fun <T> runAsync(result: MethodChannel.Result, block: () -> T) {
        thread {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                Log.e(TAG, "Fallo en MethodChannel de youtubedl-android", error)
                mainHandler.post {
                    result.error(
                        "ytdl_error",
                        error.describeForFlutter(),
                        error.stackTraceToString(),
                    )
                }
            }
        }
    }

    private fun MethodCall.requiredString(name: String): String {
        return argument<String>(name)
            ?: throw IllegalArgumentException("Falta el argumento $name")
    }

    private fun Throwable.describeForFlutter(): String {
        val causes = generateSequence(this) { it.cause }
            .take(6)
            .map { throwable ->
                val className = throwable.javaClass.name
                val message = throwable.message?.trim()
                if (message.isNullOrEmpty() || message == className.substringAfterLast('.')) {
                    className
                } else {
                    "$className: $message"
                }
            }
            .toList()
        return causes.joinToString(" -> ").ifBlank { "Fallo youtubedl-android" }
    }

    private fun JSONObject.toMap(): Map<String, Any?> {
        val map = mutableMapOf<String, Any?>()
        keys().forEach { key ->
            map[key] = when (val value = get(key)) {
                is JSONObject -> value.toMap()
                is JSONArray -> value.toList()
                JSONObject.NULL -> null
                else -> value
            }
        }
        return map
    }

    private fun JSONArray.toList(): List<Any?> {
        return (0 until length()).map { index ->
            when (val value = get(index)) {
                is JSONObject -> value.toMap()
                is JSONArray -> value.toList()
                JSONObject.NULL -> null
                else -> value
            }
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "bstream_music/ytdl"
        private const val PROGRESS_CHANNEL = "bstream_music/ytdl_progress"
        private const val FILE_EXPORT_CHANNEL = "bstream_music/file_export"
        private const val NOTIFICATION_PERMISSION_REQUEST = 4010
        private const val FILE_EXPORT_REQUEST = 4011
        private const val TAG = "BStreamYtdl"
        private const val PROGRESS_MIN_INTERVAL_MS = 200L
        private const val PROGRESS_MIN_DELTA = 0.01f
        private const val PROGRESS_TEMPLATE =
            "download:BSTREAM_PROGRESS|%(progress._percent_str)s|%(progress.eta)s"
        private const val AUDIO_FORMAT_SELECTOR =
            "bestaudio[ext=m4a]/bestaudio[ext=aac]/bestaudio[acodec^=mp4a]/bestaudio[acodec^=aac]/bestaudio"
        private val STRUCTURED_PROGRESS_REGEX =
            Regex("""BSTREAM_PROGRESS\|\s*~?\s*([0-9]+(?:\.[0-9]+)?)%\|([^|\r\n]*)""")
        private val STANDARD_PROGRESS_REGEX =
            Regex("""\[download]\s+([0-9]+(?:\.[0-9]+)?)%""")
        private val STANDARD_ETA_REGEX =
            Regex("""ETA\s+((?:[0-9]+:)?[0-9]{1,2}:[0-9]{2})""")
        private val DEFINITIVE_EXTRACTION_ERRORS = listOf(
            "private video",
            "video unavailable",
            "this video is unavailable",
            "has been removed",
            "no longer available",
            "copyright",
            "not available in your country",
            "geo-restricted",
            "geo restricted",
            "login required",
            "sign in to confirm",
            "confirm you're not a bot",
            "members-only",
            "members only",
            "drm protected",
            "not a valid url",
        )
        private val RECOVERABLE_EXTRACTOR_ERRORS = listOf(
            "no se encontro una url reproducible",
            "unable to extract",
            "failed to extract",
            "extractor error",
            "signature",
            "nsig",
            "javascript runtime",
            "challenge",
            "no video formats",
            "requested format is not available",
            "http error 403",
            "forbidden",
        )
        private val AUDIO_EXTENSIONS = setOf(
            "aiff",
            "alac",
            "oga",
            "vorbis",
            "weba",
            "wma",
            "mp3",
            "m4a",
            "m4b",
            "mp4",
            "webm",
            "mka",
            "opus",
            "flac",
            "aac",
            "wav",
            "ogg",
        )
    }

    private data class ProgressEmission(
        val emittedAt: Long,
        val progress: Float?,
        val status: String,
    )

    private data class DownloadProgressSample(
        val progress: Float,
        val etaSeconds: Long?,
    )
}
