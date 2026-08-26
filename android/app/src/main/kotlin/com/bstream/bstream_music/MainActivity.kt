package com.bstream.bstream_music

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.WindowManager
import com.ryanheise.audioservice.AudioServiceActivity
import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.util.ArrayDeque
import java.util.UUID
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.ReentrantReadWriteLock
import kotlin.concurrent.thread
import kotlin.concurrent.read
import kotlin.concurrent.write
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : AudioServiceActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val updateLock = Object()
    // Normal extractor calls can overlap. Fairness prevents new readers from
    // starving a recovery once it is waiting for exclusive access.
    private val extractorExecutionLock = ReentrantReadWriteLock(true)
    private val managedPlaybackExecutionLock = Object()
    private val managedPlaybackStateLock = Object()
    private val quickJsExecutor = Executors.newSingleThreadExecutor()
    private val quickJsStateLock = Object()
    @Volatile
    private var managedPlaybackGeneration = 0L
    @Volatile
    private var activeManagedPlaybackProcessId: String? = null
    @Volatile
    private var activeQuickJsProcess: Process? = null
    @Volatile
    private var quickJsDestroyed = false
    // The player switches to a prepared file after this MethodChannel call
    // returns. Preserve both sides of that hand-off so cache pruning cannot
    // unlink the source that is still playing while the new one opens.
    @Volatile
    private var protectedManagedPlaybackPaths: List<String> = emptyList()
    private var progressSink: EventChannel.EventSink? = null
    private var youtubeDlInitialized = false
    private var updateRunning = false
    private var updateCompleted = false
    private var lastUpdateFailureAtElapsedRealtime: Long? = null
    private val progressEmissionLock = Object()
    private val progressEmissions = mutableMapOf<String, ProgressEmission>()
    private var pendingFileExportResult: MethodChannel.Result? = null
    private var pendingFileExportSourcePath: String? = null
    private val externalAudioHandler by lazy { ExternalAudioIntentHandler(this) }
    private val externalAudioExecutor = Executors.newSingleThreadExecutor()
    // Artwork reads are independent from catalog/intent resolution. Two
    // workers keep visible rows responsive without creating unbounded metadata
    // concurrency on slower storage.
    private val localArtworkExecutor = Executors.newFixedThreadPool(2)
    private var externalAudioChannel: MethodChannel? = null
    private val pendingExternalAudioEvents = ArrayDeque<Map<String, Any?>>()
    private var appActivationChannel: MethodChannel? = null
    private var pendingAppActivation: Map<String, Any>? = null
    private var pendingExternalAudioPermissionRequest: ExternalAudioRequest? = null
    private var audioPermissionRequestInFlight = false
    private var pendingLocalAudioPermissionResult: MethodChannel.Result? = null
    private var localAudioPermissionRequestInFlight = false
    private var notificationPermissionRequestInFlight = false
    private var androidPoTokenProvider: AndroidPoTokenProvider? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // This app never stores or autofills account passwords.  Disable the
        // Android Autofill save prompt for the whole activity, including the
        // embedded Google sign-in WebView.  Session cookies are captured only
        // after the account flow succeeds and are kept in secure storage.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            window.decorView.importantForAutofill =
                View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
        }
        if (!handleExternalAudioIntent(intent)) {
            handleAppActivationIntent(intent)
            requestNotificationPermissionIfNeeded()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "initYtdl" -> initYtdl(result)
                "executeJavaScript" -> executeJavaScript(call, result)
                "getPoTokens" -> getPoTokens(call, result)
                "disposePoTokens" -> disposePoTokens(result)
                "getInfo" -> getInfo(call, result)
                "getPlaybackInfo" -> getPlaybackInfo(call, result)
                "prepareManagedPlayback" -> prepareManagedPlayback(call, result)
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

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SCREEN_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setKeepScreenOn" -> setKeepScreenOn(call, result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SUPPORTED_LINKS_SETTINGS_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "openSupportedLinksSettings" -> openSupportedLinksSettings(result)
                else -> result.notImplemented()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            LOCAL_AUDIO_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "permissionStatus" -> result.success(localAudioPermissionStatus())
                "requestPermission" -> requestLocalAudioPermission(result)
                "queryTracks" -> queryLocalAudioTracks(result)
                "loadArtwork" -> loadLocalAudioArtwork(call, result)
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

        appActivationChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_ACTIVATION_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingActivation" -> {
                        val activation = pendingAppActivation
                        pendingAppActivation = null
                        result.success(activation)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        externalAudioChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EXTERNAL_AUDIO_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "consumePendingExternalAudioEvents" -> {
                        val pending = ArrayList(pendingExternalAudioEvents)
                        pendingExternalAudioEvents.clear()
                        result.success(pending)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (!handleExternalAudioIntent(intent)) {
            handleAppActivationIntent(intent)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            EXTERNAL_AUDIO_PERMISSION_REQUEST -> {
                audioPermissionRequestInFlight = false
                val request = pendingExternalAudioPermissionRequest
                pendingExternalAudioPermissionRequest = null
                val granted = hasAudioLibraryPermission()
                if (request != null) {
                    resolveExternalAudio(
                        request = request,
                        includeFolder = granted,
                        permissionPending = false,
                        permissionDenied = !granted,
                    )
                }
                completePendingLocalAudioPermission()
                requestNotificationPermissionIfNeeded()
            }
            LOCAL_AUDIO_PERMISSION_REQUEST -> {
                localAudioPermissionRequestInFlight = false
                completePendingLocalAudioPermission()
                requestExternalAudioPermissionIfNeeded()
                requestNotificationPermissionIfNeeded()
            }
            NOTIFICATION_PERMISSION_REQUEST -> {
                notificationPermissionRequestInFlight = false
                requestExternalAudioPermissionIfNeeded()
                requestLocalAudioPermissionIfNeeded()
            }
        }
    }

    override fun onDestroy() {
        quickJsDestroyed = true
        synchronized(quickJsStateLock) {
            activeQuickJsProcess?.destroyForcibly()
            activeQuickJsProcess = null
        }
        quickJsExecutor.shutdownNow()
        androidPoTokenProvider?.dispose()
        androidPoTokenProvider = null
        val managedProcessId = synchronized(managedPlaybackStateLock) {
            managedPlaybackGeneration++
            activeManagedPlaybackProcessId.also {
                activeManagedPlaybackProcessId = null
            }
        }
        managedProcessId?.let {
            runCatching { YoutubeDL.getInstance().destroyProcessById(it) }
        }
        externalAudioExecutor.shutdownNow()
        localArtworkExecutor.shutdownNow()
        pendingLocalAudioPermissionResult?.error(
            "activity_destroyed",
            "The Android activity was closed before audio permission completed.",
            null,
        )
        pendingLocalAudioPermissionResult = null
        super.onDestroy()
    }

    private fun saveFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingFileExportResult != null) {
            result.error("export_busy", "Ya hay una exportación en curso.", null)
            return
        }

        val sourcePath = call.requiredString("sourcePath")
        val source = File(sourcePath)
        if (!source.exists() || !source.isFile) {
            result.error("export_missing", "No se encontró el archivo para exportar.", null)
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

    private fun setKeepScreenOn(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: false
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
        result.success(null)
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

    private fun executeJavaScript(call: MethodCall, result: MethodChannel.Result) {
        val script = call.requiredString("script")
        if (script.isBlank()) {
            result.error("quickjs_empty_script", "El script JavaScript esta vacio.", null)
            return
        }
        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong()
            ?: QUICKJS_DEFAULT_TIMEOUT_MS
        if (timeoutMs !in QUICKJS_MIN_TIMEOUT_MS..QUICKJS_MAX_TIMEOUT_MS) {
            result.error(
                "quickjs_invalid_timeout",
                "El timeout de QuickJS esta fuera de rango.",
                null,
            )
            return
        }
        if (quickJsDestroyed) {
            result.error("quickjs_destroyed", "La actividad Android ya fue cerrada.", null)
            return
        }

        try {
            quickJsExecutor.execute {
                try {
                    val output = executeQuickJsBlocking(script, timeoutMs)
                    if (!quickJsDestroyed) {
                        mainHandler.post { result.success(output) }
                    }
                } catch (error: Throwable) {
                    Log.e(TAG, "Fallo al ejecutar QuickJS", error)
                    if (!quickJsDestroyed) {
                        mainHandler.post {
                            result.error(
                                "quickjs_error",
                                error.describeForFlutter(),
                                error.stackTraceToString(),
                            )
                        }
                    }
                }
            }
        } catch (error: Throwable) {
            result.error("quickjs_executor_unavailable", error.message, null)
        }
    }

    private fun getPoTokens(call: MethodCall, result: MethodChannel.Result) {
        val videoId = call.requiredString("videoId")
        val provider = androidPoTokenProvider ?: AndroidPoTokenProvider(applicationContext).also {
            androidPoTokenProvider = it
        }
        provider.getTokens(videoId).whenComplete { value, error ->
            mainHandler.post {
                if (error != null) {
                    Log.w(TAG, "No se pudo generar PO token: ${error.message}")
                    result.success(mapOf("available" to false))
                } else {
                    result.success(value ?: mapOf("available" to false))
                }
            }
        }
    }

    private fun disposePoTokens(result: MethodChannel.Result) {
        androidPoTokenProvider?.dispose()
        androidPoTokenProvider = null
        result.success(null)
    }

    private fun executeQuickJsBlocking(script: String, timeoutMs: Long): String {
        val executable = File(applicationInfo.nativeLibraryDir, QUICKJS_LIBRARY_NAME)
        if (!executable.isFile) {
            throw IllegalStateException(
                "No se encontro el runtime QuickJS incluido en ${executable.absolutePath}.",
            )
        }

        val directory = File(cacheDir, QUICKJS_CACHE_DIRECTORY)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("No se pudo crear el directorio temporal de QuickJS.")
        }
        val scriptFile = File(directory, "script-${UUID.randomUUID()}.js")

        var process: Process? = null
        val stdout = StringBuilder()
        val stderr = StringBuilder()
        var stdoutThread: Thread? = null
        var stderrThread: Thread? = null
        try {
            scriptFile.writeText(script, StandardCharsets.UTF_8)
            val startedProcess = ProcessBuilder(
                executable.absolutePath,
                "--script",
                scriptFile.absolutePath,
            ).redirectErrorStream(false).start()
            process = startedProcess
            synchronized(quickJsStateLock) {
                if (quickJsDestroyed) {
                    startedProcess.destroyForcibly()
                    throw IllegalStateException("La actividad Android ya fue cerrada.")
                }
                activeQuickJsProcess = startedProcess
            }

            val runningProcess = startedProcess
            stdoutThread = thread(name = "BStreamQuickJsStdout") {
                runningProcess.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        if (stdout.length < QUICKJS_OUTPUT_LIMIT) {
                            stdout.append(line).append('\n')
                        }
                    }
                }
            }
            stderrThread = thread(name = "BStreamQuickJsStderr") {
                runningProcess.errorStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        if (stderr.length < QUICKJS_ERROR_LIMIT) {
                            stderr.append(line).append('\n')
                        }
                    }
                }
            }

            if (!runningProcess.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                runningProcess.destroyForcibly()
                runningProcess.waitFor(1, TimeUnit.SECONDS)
                throw IllegalStateException("QuickJS excedio el timeout de ${timeoutMs}ms.")
            }
            stdoutThread.join(1000)
            stderrThread.join(1000)
            val exitCode = runningProcess.exitValue()
            if (exitCode != 0) {
                val detail = stderr.toString().trim().ifEmpty {
                    "QuickJS termino con codigo $exitCode."
                }
                throw IllegalStateException(detail)
            }
            return stdout.toString().trim().ifEmpty {
                throw IllegalStateException("QuickJS no devolvio un resultado.")
            }
        } finally {
            process?.destroy()
            stdoutThread?.interrupt()
            stderrThread?.interrupt()
            synchronized(quickJsStateLock) {
                if (activeQuickJsProcess === process) {
                    activeQuickJsProcess = null
                }
            }
            if (!scriptFile.delete() && scriptFile.exists()) {
                Log.w(TAG, "No se pudo borrar el script temporal de QuickJS")
            }
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

    private fun prepareManagedPlayback(call: MethodCall, result: MethodChannel.Result) {
        val url = call.requiredString("url")
        val generation: Long
        val processToCancel: String?
        synchronized(managedPlaybackStateLock) {
            generation = ++managedPlaybackGeneration
            processToCancel = activeManagedPlaybackProcessId
        }
        processToCancel?.let {
            runCatching { YoutubeDL.getInstance().destroyProcessById(it) }
        }
        runAsync(result) {
            ensureYoutubeDlInitialized()
            synchronized(managedPlaybackExecutionLock) {
                ensureManagedPlaybackCurrent(generation)
                executeManagedPlaybackRequest(url, generation)
            }
        }
    }

    private fun search(call: MethodCall, result: MethodChannel.Result) {
        val query = call.requiredString("query")
        val limit = (call.argument<Int>("limit") ?: DEFAULT_SEARCH_RESULT_LIMIT)
            .coerceIn(1, MAX_SEARCH_RESULT_LIMIT)
        runAsync(result) {
            ensureYoutubeDlInitialized()
            executeSearchRequest(query, limit)
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
            Log.i(TAG, "getPlaybackInfo started urlLength=${url.length}")
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
                ?: throw IllegalStateException("No se encontró una URL reproducible.")
            Log.i(
                TAG,
                "getPlaybackInfo URL extracted in " +
                    "${SystemClock.elapsedRealtime() - startedAt}ms " +
                    "format=${selectedFormat.nonBlankString("format_id") ?: "unknown"}",
            )
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
                "stream_extension" to (
                    selectedFormat.nonBlankString("audio_ext")
                        ?: selectedFormat.nonBlankString("ext")
                    ),
                "stream_mime_type" to selectedFormat.nonBlankString("mime_type"),
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

    private fun executeManagedPlaybackRequest(
        url: String,
        generation: Long,
    ): Map<String, Any?> {
        return executeWithExtractorRetry("prepareManagedPlayback") {
            ensureManagedPlaybackCurrent(generation)
            val root = File(applicationContext.cacheDir, MANAGED_PLAYBACK_DIRECTORY)
            if (!root.exists() && !root.mkdirs()) {
                throw IllegalStateException("No se pudo crear la caché de reproducción.")
            }
            trimManagedPlaybackCache(root, protectedManagedPlaybackPaths)

            try {
                executeManagedPlaybackAttempt(url, root, "web_embedded", generation)
            } catch (embeddedError: Exception) {
                ensureManagedPlaybackCurrent(generation)
                Log.w(
                    TAG,
                    "Managed playback with web_embedded failed; trying yt-dlp defaults",
                    embeddedError,
                )
                executeManagedPlaybackAttempt(url, root, null, generation)
            }
        }
    }

    private fun executeManagedPlaybackAttempt(
        url: String,
        root: File,
        playerClient: String?,
        generation: Long,
    ): Map<String, Any?> {
        ensureManagedPlaybackCurrent(generation)
        val request = YoutubeDLRequest(url)
        addBaseNetworkOptions(request)
        request.addOption("--no-playlist")
        request.addOption("--no-progress")
        request.addOption("--fixup", "never")
        request.addOption("--downloader", "native")
        request.addOption("--http-chunk-size", "1M")
        request.addOption("--max-filesize", MANAGED_PLAYBACK_MAX_ENTRY_BYTES.toString())
        request.addOption("-f", AUDIO_FORMAT_SELECTOR)
        if (playerClient != null) {
            request.addOption("--extractor-args", "youtube:player_client=$playerClient")
        }
        request.addOption("--print", "after_move:$MANAGED_FILE_PREFIX%(filepath)j")
        request.addOption("--print", "after_move:$MANAGED_EXTENSION_PREFIX%(ext)j")
        request.addOption("--print", "after_move:$MANAGED_FORMAT_PREFIX%(format_id)j")
        request.addOption("--print", "after_move:$MANAGED_CODEC_PREFIX%(acodec)j")
        request.addOption(
            "-o",
            File(root, "%(id)s.%(format_id)s.%(ext)s").absolutePath,
        )

        val processId = UUID.randomUUID().toString()
        synchronized(managedPlaybackStateLock) {
            ensureManagedPlaybackCurrent(generation)
            activeManagedPlaybackProcessId = processId
        }
        val response = try {
            YoutubeDL.getInstance().execute(request, processId)
        } finally {
            synchronized(managedPlaybackStateLock) {
                if (activeManagedPlaybackProcessId == processId) {
                    activeManagedPlaybackProcessId = null
                }
            }
        }
        ensureManagedPlaybackCurrent(generation)
        val printedPath = printedJsonValue(response.out, MANAGED_FILE_PREFIX)
            ?: throw IllegalStateException(
                "yt-dlp finalizó sin indicar el archivo de reproducción.",
            )
        val canonicalRoot = root.canonicalFile
        val file = File(printedPath).canonicalFile
        val rootPrefix = canonicalRoot.path.trimEnd(File.separatorChar) + File.separator
        if (!file.path.startsWith(rootPrefix) ||
            !file.exists() ||
            !file.isFile ||
            file.length() <= 0L ||
            !isAudioExtension(file.extension)
        ) {
            throw IllegalStateException(
                "yt-dlp no preparó un archivo de audio válido.",
            )
        }
        if (file.length() > MANAGED_PLAYBACK_MAX_ENTRY_BYTES) {
            runCatching { file.delete() }
            throw IllegalStateException(
                "El audio preparado excede el límite de caché de " +
                    "$MANAGED_PLAYBACK_MAX_ENTRY_BYTES bytes.",
            )
        }
        // Treat cache hits as recently used so pruning remains LRU-like.
        file.setLastModified(System.currentTimeMillis())
        ensureManagedPlaybackCurrent(generation)
        val protectedPaths = managedPlaybackProtectionWindow(file.absolutePath)
        protectedManagedPlaybackPaths = protectedPaths
        trimManagedPlaybackCache(root, protectedPaths)
        ensureManagedPlaybackCurrent(generation)
        val extension = printedJsonValue(response.out, MANAGED_EXTENSION_PREFIX)
            ?.lowercase()
            ?.takeIf(::isAudioExtension)
            ?: file.extension.lowercase().takeIf(::isAudioExtension)

        return mapOf(
            "filePath" to file.absolutePath,
            "extension" to extension,
            "mimeType" to extension?.let(::audioMimeType),
            "formatId" to printedJsonValue(response.out, MANAGED_FORMAT_PREFIX),
            "codec" to printedJsonValue(response.out, MANAGED_CODEC_PREFIX),
        )
    }

    private fun ensureManagedPlaybackCurrent(generation: Long) {
        if (generation != managedPlaybackGeneration) {
            throw ManagedPlaybackSupersededException()
        }
    }

    private fun printedJsonValue(output: String, prefix: String): String? {
        val encoded = output
            .lineSequence()
            .map(String::trim)
            .lastOrNull { it.startsWith(prefix) }
            ?.removePrefix(prefix)
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?: return null
        return try {
            val value = JSONArray("[$encoded]").opt(0)
            if (value == null || value == JSONObject.NULL) {
                null
            } else {
                value.toString().trim().takeIf(String::isNotEmpty)
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun trimManagedPlaybackCache(root: File, protectedPaths: Collection<String>) {
        val cutoff = System.currentTimeMillis() - MANAGED_PLAYBACK_MAX_AGE_MS
        val normalizedProtectedPaths = protectedPaths.mapTo(mutableSetOf()) { path ->
            runCatching { File(path).canonicalPath }
                .getOrElse { _ -> File(path).absolutePath }
        }
        fun isProtected(file: File): Boolean {
            if (normalizedProtectedPaths.isEmpty()) {
                return false
            }
            val candidate = runCatching { file.canonicalPath }.getOrElse { file.absolutePath }
            return candidate in normalizedProtectedPaths
        }
        root.listFiles()?.forEach { file ->
            if (file.isFile && !isProtected(file) &&
                (file.name.endsWith(".part") ||
                    file.name.endsWith(".ytdl") ||
                    file.lastModified() < cutoff)
            ) {
                runCatching { file.delete() }
            }
        }

        val completed = root.listFiles()
            ?.filter { it.isFile && isAudioExtension(it.extension) }
            ?.sortedWith(
                compareByDescending<File> { isProtected(it) }
                    .thenByDescending(File::lastModified),
            )
            .orEmpty()
        var retainedFiles = 0
        var retainedBytes = 0L
        completed.forEach { file ->
            val protected = isProtected(file)
            val length = file.length().coerceAtLeast(0L)
            val exceedsLimits =
                retainedFiles >= MANAGED_PLAYBACK_MAX_FILES ||
                    length > MANAGED_PLAYBACK_MAX_BYTES - retainedBytes
            if (!protected && exceedsLimits) {
                runCatching { file.delete() }
            } else {
                retainedFiles++
                retainedBytes += length
            }
        }
    }

    private fun managedPlaybackProtectionWindow(newestPath: String): List<String> {
        val newest = runCatching { File(newestPath).canonicalPath }
            .getOrElse { File(newestPath).absolutePath }
        val protected = mutableListOf(newest)
        for (existing in protectedManagedPlaybackPaths) {
            val normalized = runCatching { File(existing).canonicalPath }
                .getOrElse { File(existing).absolutePath }
            if (normalized !in protected) {
                protected += normalized
            }
            if (protected.size == MANAGED_PLAYBACK_PROTECTION_WINDOW) {
                break
            }
        }
        return protected.take(MANAGED_PLAYBACK_PROTECTION_WINDOW)
    }

    private fun audioMimeType(extension: String): String? {
        return when (extension.lowercase()) {
            "m4a", "m4b", "mp4" -> "audio/mp4"
            "aac" -> "audio/aac"
            "mp3" -> "audio/mpeg"
            "webm", "weba" -> "audio/webm"
            "ogg", "oga" -> "audio/ogg"
            "opus" -> "audio/opus"
            "flac" -> "audio/flac"
            "wav" -> "audio/wav"
            "3gp", "3gpp" -> "audio/3gpp"
            else -> null
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

    private fun executeSearchRequest(
        query: String,
        limit: Int,
    ): List<Map<String, Any?>> {
        return executeWithExtractorRetry("search") {
            val startedAt = SystemClock.elapsedRealtime()
            Log.i(
                TAG,
                "search started queryLength=${query.trim().length}",
            )
            val request = YoutubeDLRequest("ytsearch$limit:$query")
            addBaseNetworkOptions(request)
            request.addOption("--dump-json")
            request.addOption("--flat-playlist")
            val response = YoutubeDL.getInstance().execute(request)
            val results = response.out
                .lineSequence()
                .filter { it.isNotBlank() }
                .map { JSONObject(it).toMap() }
                .toList()
            Log.i(
                TAG,
                "search completed in ${SystemClock.elapsedRealtime() - startedAt}ms " +
                    "results=${results.size}",
            )
            results
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
        // The default YouTube client can resolve metadata but returns media
        // URLs that fail with HTTP 403 when the download starts. The embedded
        // web client produces a compatible signed URL for the actual transfer.
        request.addOption("--extractor-args", "youtube:player_client=web_embedded")
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
            ?: throw IllegalStateException("La descarga terminó sin un archivo de audio válido.")

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
        val startedAt = SystemClock.elapsedRealtime()
        val usingBundledVersion = prepareBundledYoutubeDlUpgrade()
        YoutubeDL.getInstance().init(applicationContext)
        finishBundledYoutubeDlUpgrade(usingBundledVersion)
        youtubeDlInitialized = true
        val effectiveVersion = applicationContext
            .getSharedPreferences(YTDLP_SHARED_PREFS, Context.MODE_PRIVATE)
            .getString(YTDLP_VERSION_NAME_KEY, null)
            ?: BuildConfig.BUNDLED_YTDLP_VERSION
        Log.i(
            TAG,
            "yt-dlp initialized version=$effectiveVersion in " +
                "${SystemClock.elapsedRealtime() - startedAt}ms",
        )
    }

    private fun prepareBundledYoutubeDlUpgrade(): Boolean {
        val ytdlpDir = youtubeDlDirectory()
        val ytdlpFile = File(ytdlpDir, YoutubeDL.ytdlpBin)
        val preferences = applicationContext.getSharedPreferences(
            YTDLP_SHARED_PREFS,
            Context.MODE_PRIVATE,
        )
        val handledBundledVersion = preferences.getString(
            BUNDLED_YTDLP_VERSION_KEY,
            null,
        )
        val recordedVersion = preferences.getString(YTDLP_VERSION_KEY, null)
        val verifiedVersion = preferences.getString(VERIFIED_YTDLP_VERSION_KEY, null)
        val verifiedSha256 = preferences.getString(VERIFIED_YTDLP_SHA256_KEY, null)
        val actualSha256 = YtDlpUpdatePolicy.sha256(
            ytdlpFile,
            YTDLP_MAX_BINARY_BYTES,
        )
        val keepExistingVerifiedCopy =
            actualSha256 != null &&
                actualSha256.equals(verifiedSha256, ignoreCase = true) &&
                YtDlpUpdatePolicy.executableMatchesRelease(recordedVersion, verifiedVersion.orEmpty()) &&
                YtDlpUpdatePolicy.isVersionAtLeast(
                    verifiedVersion,
                    BuildConfig.BUNDLED_YTDLP_VERSION,
                )
        if (keepExistingVerifiedCopy) {
            Log.i(
                TAG,
                "Keeping verified installed yt-dlp $verifiedVersion " +
                    "over bundled ${BuildConfig.BUNDLED_YTDLP_VERSION}",
            )
            return false
        }

        if (handledBundledVersion == BuildConfig.BUNDLED_YTDLP_VERSION && ytdlpFile.isFile) {
            Log.w(TAG, "Replacing an unverified or modified persisted yt-dlp copy")
        }

        if (ytdlpDir.exists() && !ytdlpDir.deleteRecursively()) {
            throw IllegalStateException("No se pudo reemplazar la copia incluida de yt-dlp.")
        }
        preferences.edit()
            .remove(YTDLP_VERSION_KEY)
            .remove(YTDLP_VERSION_NAME_KEY)
            .remove(VERIFIED_YTDLP_VERSION_KEY)
            .remove(VERIFIED_YTDLP_SHA256_KEY)
            .commit()
        Log.i(TAG, "Preparing bundled yt-dlp ${BuildConfig.BUNDLED_YTDLP_VERSION}")
        return true
    }

    private fun finishBundledYoutubeDlUpgrade(usingBundledVersion: Boolean) {
        if (usingBundledVersion) {
            val actualSha256 = YtDlpUpdatePolicy.sha256(
                File(youtubeDlDirectory(), YoutubeDL.ytdlpBin),
                YTDLP_MAX_BINARY_BYTES,
            )
            if (!actualSha256.equals(BuildConfig.BUNDLED_YTDLP_SHA256, ignoreCase = true)) {
                throw IllegalStateException("La copia incluida de yt-dlp no supero su verificacion.")
            }
        }
        val editor = applicationContext
            .getSharedPreferences(YTDLP_SHARED_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(BUNDLED_YTDLP_VERSION_KEY, BuildConfig.BUNDLED_YTDLP_VERSION)
        if (usingBundledVersion) {
            editor
                .putString(YTDLP_VERSION_KEY, BuildConfig.BUNDLED_YTDLP_VERSION)
                .putString(YTDLP_VERSION_NAME_KEY, BuildConfig.BUNDLED_YTDLP_VERSION)
                .putString(VERIFIED_YTDLP_VERSION_KEY, BuildConfig.BUNDLED_YTDLP_VERSION)
                .putString(VERIFIED_YTDLP_SHA256_KEY, BuildConfig.BUNDLED_YTDLP_SHA256)
        }
        if (!editor.commit()) {
            Log.w(TAG, "No se pudo guardar la version incluida de yt-dlp")
        }
    }

    private fun youtubeDlDirectory(): File {
        return File(
            applicationContext.noBackupFilesDir,
            "${YoutubeDL.baseName}/${YoutubeDL.ytdlpDirName}",
        )
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
            val now = SystemClock.elapsedRealtime()
            if (!YtDlpUpdatePolicy.canAttemptUpdate(
                    nowElapsedMilliseconds = now,
                    lastFailureElapsedMilliseconds = lastUpdateFailureAtElapsedRealtime,
                    failureCooldownMilliseconds = YTDLP_UPDATE_FAILURE_COOLDOWN_MS,
                )
            ) {
                Log.i(TAG, "Skipping yt-dlp update during the failure cooldown")
                return false
            }
            updateRunning = true
        }

        var accepted = false
        return try {
            val channel = YtDlpUpdatePolicy.channel(
                allowNightly = BuildConfig.ALLOW_NIGHTLY_YTDLP_UPDATES,
            )
            val youtubeDl = YoutubeDL.getInstance()
            val status = youtubeDl.updateYoutubeDL(applicationContext, channel)
            val verification = verifyRuntimeYoutubeDl(youtubeDl, channel)
            if (verification == null || !recordVerifiedYoutubeDl(verification)) {
                Log.w(
                    TAG,
                    "Rejected unverified runtime yt-dlp from ${channel.apiUrl}; " +
                        "restoring bundled ${BuildConfig.BUNDLED_YTDLP_VERSION}",
                )
                restoreBundledYoutubeDl()
                return false
            }
            Log.i(
                TAG,
                "yt-dlp update status: $status, source=${channel.apiUrl}, " +
                    "version=${verification.version}, sha256=${verification.sha256}",
            )
            synchronized(updateLock) {
                updateCompleted = true
                lastUpdateFailureAtElapsedRealtime = null
            }
            accepted = true
            true
        } catch (error: Throwable) {
            Log.w(TAG, "No se pudo actualizar yt-dlp", error)
            try {
                restoreBundledYoutubeDl()
            } catch (restoreError: Throwable) {
                error.addSuppressed(restoreError)
                Log.e(TAG, "No se pudo restaurar la copia incluida de yt-dlp", restoreError)
            }
            false
        } finally {
            synchronized(updateLock) {
                if (!accepted) {
                    lastUpdateFailureAtElapsedRealtime = SystemClock.elapsedRealtime()
                }
                updateRunning = false
                updateLock.notifyAll()
            }
        }
    }

    /**
     * Verifies the release metadata and checksum before executing the freshly
     * downloaded zipapp. SHA2-256SUMS is fetched from the exact official
     * release selected by the updater. This protects against corruption and
     * mismatched assets, but is not presented as an independent publisher
     * signature because the manifest and asset share the same release host.
     */
    private fun verifyRuntimeYoutubeDl(
        youtubeDl: YoutubeDL,
        channel: YoutubeDL.UpdateChannel,
    ): RuntimeYtDlpVerification? {
        val metadataVersion = youtubeDl.version(applicationContext)
        val metadataName = youtubeDl.versionName(applicationContext)
        val releaseVersion = YtDlpUpdatePolicy.coherentReleaseVersion(
            metadataVersion = metadataVersion,
            metadataName = metadataName,
            requiredVersion = BuildConfig.BUNDLED_YTDLP_VERSION,
        ) ?: run {
            Log.w(TAG, "yt-dlp release metadata is invalid or inconsistent")
            return null
        }
        val manifestUrl = YtDlpUpdatePolicy.checksumManifestUrl(
            channel,
            releaseVersion,
        ) ?: return null
        val manifest = downloadBoundedText(manifestUrl, YTDLP_CHECKSUM_MANIFEST_MAX_BYTES)
            ?: run {
                Log.w(TAG, "Could not download the official yt-dlp checksum manifest")
                return null
            }
        val expectedSha256 = YtDlpUpdatePolicy.checksumForAsset(manifest)
            ?: run {
                Log.w(TAG, "The yt-dlp checksum manifest has no unambiguous yt-dlp entry")
                return null
            }
        val ytdlpFile = File(youtubeDlDirectory(), YoutubeDL.ytdlpBin)
        val actualSha256 = YtDlpUpdatePolicy.sha256(
            ytdlpFile,
            YTDLP_MAX_BINARY_BYTES,
        )
        if (!actualSha256.equals(expectedSha256, ignoreCase = true)) {
            Log.w(TAG, "The downloaded yt-dlp checksum does not match its release manifest")
            return null
        }

        val executableVersion = probeYoutubeDlVersion(youtubeDl)
        if (!YtDlpUpdatePolicy.executableMatchesRelease(executableVersion, releaseVersion)) {
            Log.w(TAG, "The downloaded yt-dlp executable reports an inconsistent version")
            return null
        }
        return RuntimeYtDlpVerification(releaseVersion, actualSha256!!)
    }

    private fun probeYoutubeDlVersion(youtubeDl: YoutubeDL): String? {
        val request = YoutubeDLRequest(emptyList<String>())
            .addOption("--ignore-config")
            .addOption("--version")
        val response = youtubeDl.execute(request)
        if (response.exitCode != 0) {
            return null
        }
        val lines = response.out
            .lineSequence()
            .map(String::trim)
            .filter(String::isNotEmpty)
            .toList()
        return lines.singleOrNull()
    }

    private fun downloadBoundedText(url: String, maximumBytes: Int): String? {
        val connection = URL(url).openConnection() as? HttpURLConnection ?: return null
        return try {
            connection.instanceFollowRedirects = true
            connection.connectTimeout = YTDLP_CHECKSUM_CONNECT_TIMEOUT_MS
            connection.readTimeout = YTDLP_CHECKSUM_READ_TIMEOUT_MS
            connection.setRequestProperty("Accept", "text/plain, application/octet-stream")
            connection.setRequestProperty("Accept-Encoding", "identity")
            connection.setRequestProperty("User-Agent", "BStream-Music-Android")
            val status = connection.responseCode
            val resolvedUrl = connection.url
            if (status !in 200..299 ||
                resolvedUrl.protocol != "https" ||
                resolvedUrl.host !in YTDLP_CHECKSUM_ALLOWED_HOSTS ||
                connection.contentLengthLong > maximumBytes
            ) {
                return null
            }
            val output = ByteArrayOutputStream()
            connection.inputStream.buffered().use { input ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) {
                        break
                    }
                    total += count
                    if (total > maximumBytes) {
                        return null
                    }
                    output.write(buffer, 0, count)
                }
            }
            output.toString(StandardCharsets.UTF_8.name())
        } finally {
            connection.disconnect()
        }
    }

    private fun recordVerifiedYoutubeDl(verification: RuntimeYtDlpVerification): Boolean {
        return applicationContext
            .getSharedPreferences(YTDLP_SHARED_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(VERIFIED_YTDLP_VERSION_KEY, verification.version)
            .putString(VERIFIED_YTDLP_SHA256_KEY, verification.sha256)
            .commit()
    }

    private fun restoreBundledYoutubeDl() {
        val ytdlpDir = youtubeDlDirectory()

        try {
            if (ytdlpDir.exists() && !ytdlpDir.deleteRecursively()) {
                throw IllegalStateException("No se pudo limpiar la copia de yt-dlp.")
            }
            YoutubeDL.init_ytdlp(applicationContext, ytdlpDir)
            val restoredSha256 = YtDlpUpdatePolicy.sha256(
                File(ytdlpDir, YoutubeDL.ytdlpBin),
                YTDLP_MAX_BINARY_BYTES,
            )
            if (!restoredSha256.equals(BuildConfig.BUNDLED_YTDLP_SHA256, ignoreCase = true)) {
                throw IllegalStateException("La copia restaurada de yt-dlp no supero su verificacion.")
            }
            applicationContext
                .getSharedPreferences(YTDLP_SHARED_PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(YTDLP_VERSION_KEY, BuildConfig.BUNDLED_YTDLP_VERSION)
                .putString(YTDLP_VERSION_NAME_KEY, BuildConfig.BUNDLED_YTDLP_VERSION)
                .putString(BUNDLED_YTDLP_VERSION_KEY, BuildConfig.BUNDLED_YTDLP_VERSION)
                .putString(VERIFIED_YTDLP_VERSION_KEY, BuildConfig.BUNDLED_YTDLP_VERSION)
                .putString(VERIFIED_YTDLP_SHA256_KEY, BuildConfig.BUNDLED_YTDLP_SHA256)
                .commit()
            Log.w(
                TAG,
                "Se restauro yt-dlp ${BuildConfig.BUNDLED_YTDLP_VERSION} incluido",
            )
        } finally {
            synchronized(updateLock) {
                updateCompleted = false
                lastUpdateFailureAtElapsedRealtime = SystemClock.elapsedRealtime()
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
        try {
            // read {} always unlocks before the exception reaches the catch;
            // recovery never attempts an unsafe read-to-write lock upgrade.
            return extractorExecutionLock.read { block() }
        } catch (error: Exception) {
            if (!shouldRetryAfterExtractorUpdate(error)) {
                throw error
            }
            Log.w(TAG, "Retrying $operation after yt-dlp update", error)
            onRetry?.invoke()

            // Updating and restoring yt-dlp replace its shared directory. Wait
            // for every active extractor process to finish, and prevent new
            // ones from starting until the retry leaves a stable installation.
            return extractorExecutionLock.write {
                if (!updateYoutubeDlBlocking()) {
                    throw error
                }
                try {
                    block()
                } catch (retryError: Exception) {
                    retryError.addSuppressed(error)
                    try {
                        // Never leave an extractor that failed its own retry.
                        restoreBundledYoutubeDl()
                    } catch (restoreError: Throwable) {
                        retryError.addSuppressed(restoreError)
                    }
                    throw retryError
                }
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

    private fun handleExternalAudioIntent(intent: Intent?): Boolean {
        if (!externalAudioHandler.accepts(intent)) {
            return false
        }
        val safeIntent = Intent(intent!!)
        retainExternalAudioPermission(safeIntent)
        val request = ExternalAudioRequest(
            UUID.randomUUID().toString(),
            safeIntent,
            appEntryGeneration.incrementAndGet(),
        )

        if (hasAudioLibraryPermission()) {
            resolveExternalAudio(
                request = request,
                includeFolder = true,
                permissionPending = false,
                permissionDenied = false,
            )
            requestNotificationPermissionIfNeeded()
            return true
        }

        // The URI grant from ACTION_VIEW is enough to begin the selected file.
        // The library permission is requested only to discover its siblings.
        resolveExternalAudio(
            request = request,
            includeFolder = false,
            permissionPending = true,
            permissionDenied = false,
        )
        pendingExternalAudioPermissionRequest = request
        requestExternalAudioPermissionIfNeeded()
        return true
    }

    private fun retainExternalAudioPermission(intent: Intent) {
        if (intent.flags and Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION == 0) {
            return
        }
        val uri = intent.data ?: return
        val flags = intent.flags and
            (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        if (flags == 0) {
            return
        }
        runCatching { contentResolver.takePersistableUriPermission(uri, flags) }
    }

    private fun resolveExternalAudio(
        request: ExternalAudioRequest,
        includeFolder: Boolean,
        permissionPending: Boolean,
        permissionDenied: Boolean,
    ) {
        externalAudioExecutor.execute {
            try {
                val payload = externalAudioHandler.resolve(
                    requestId = request.id,
                    intent = request.intent,
                    includeFolder = includeFolder,
                    permissionPending = permissionPending,
                    permissionDenied = permissionDenied,
                )
                val eventPayload = payload.toMutableMap().apply {
                    put("entryGeneration", request.entryGeneration)
                    put(
                        "openPlayer",
                        request.entryGeneration == appEntryGeneration.get(),
                    )
                }
                Log.i(
                    EXTERNAL_AUDIO_TAG,
                    "Resolved external audio: tracks=" +
                        "${(eventPayload["tracks"] as? List<*>)?.size ?: 0}, " +
                        "selected=${eventPayload["selectedIndex"]}, " +
                        "folderComplete=${eventPayload["folderQueueComplete"]}, " +
                        "permissionPending=$permissionPending",
                )
                mainHandler.post { emitExternalAudio(eventPayload) }
            } catch (error: Throwable) {
                Log.e(TAG, "Could not resolve external audio", error)
            }
        }
    }

    private fun emitExternalAudio(payload: Map<String, Any?>) {
        while (pendingExternalAudioEvents.size >= MAX_PENDING_EXTERNAL_AUDIO_EVENTS) {
            pendingExternalAudioEvents.removeFirst()
        }
        pendingExternalAudioEvents.addLast(payload)
        val channel = externalAudioChannel ?: return
        channel.invokeMethod(
            "externalAudio",
            payload,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result == true) {
                        pendingExternalAudioEvents.removeFirstOccurrence(payload)
                    }
                }

                override fun error(code: String, message: String?, details: Any?) = Unit

                override fun notImplemented() = Unit
            },
        )
    }

    private fun openSupportedLinksSettings(result: MethodChannel.Result) {
        val packageUri = Uri.parse("package:$packageName")
        val candidates = mutableListOf<Intent>()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            candidates += Intent(
                "android.settings.APP_OPEN_BY_DEFAULT_SETTINGS",
                packageUri,
            )
        }
        candidates += Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, packageUri)
        candidates += Intent(Settings.ACTION_SETTINGS)

        for (candidate in candidates) {
            try {
                startActivity(candidate)
                result.success(true)
                return
            } catch (error: Exception) {
                Log.w(TAG, "No se pudo abrir ${candidate.action}", error)
            }
        }
        result.success(false)
    }

    private fun requestExternalAudioPermissionIfNeeded() {
        val pendingRequest = pendingExternalAudioPermissionRequest ?: return
        if (hasAudioLibraryPermission()) {
            pendingExternalAudioPermissionRequest = null
            resolveExternalAudio(
                request = pendingRequest,
                includeFolder = true,
                permissionPending = false,
                permissionDenied = false,
            )
            requestNotificationPermissionIfNeeded()
            return
        }
        if (audioPermissionRequestInFlight ||
            localAudioPermissionRequestInFlight ||
            notificationPermissionRequestInFlight
        ) {
            return
        }
        audioPermissionRequestInFlight = true
        requestPermissions(
            arrayOf(audioLibraryPermission()),
            EXTERNAL_AUDIO_PERMISSION_REQUEST,
        )
    }

    private fun hasAudioLibraryPermission(): Boolean {
        return checkSelfPermission(audioLibraryPermission()) == PackageManager.PERMISSION_GRANTED
    }

    private fun audioLibraryPermission(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Manifest.permission.READ_MEDIA_AUDIO
        } else {
            Manifest.permission.READ_EXTERNAL_STORAGE
        }
    }

    private fun handleAppActivationIntent(intent: Intent?) {
        val activation = when {
            intent?.action == ACTION_OPEN_HOME -> APP_ACTIVATION_HOME
            intent?.action == AUDIO_SERVICE_NOTIFICATION_CLICK_ACTION -> APP_ACTIVATION_PLAYER
            intent?.action == Intent.ACTION_MAIN &&
                intent.hasCategory(Intent.CATEGORY_LAUNCHER) -> APP_ACTIVATION_HOME
            else -> null
        } ?: return
        emitAppActivation(
            activation = activation,
            entryGeneration = appEntryGeneration.incrementAndGet(),
        )
    }

    private fun emitAppActivation(activation: String, entryGeneration: Long) {
        val payload = mapOf(
            "activation" to activation,
            "entryGeneration" to entryGeneration,
        )
        pendingAppActivation = payload
        val channel = appActivationChannel ?: return
        channel.invokeMethod(
            "activate",
            payload,
            object : MethodChannel.Result {
                override fun success(result: Any?) {
                    if (result == true && pendingAppActivation == payload) {
                        pendingAppActivation = null
                    }
                }

                override fun error(code: String, message: String?, details: Any?) = Unit

                override fun notImplemented() = Unit
            },
        )
    }

    private fun localAudioPermissionStatus(): String {
        return if (hasAudioLibraryPermission()) "granted" else "denied"
    }

    private fun requestLocalAudioPermission(result: MethodChannel.Result) {
        if (hasAudioLibraryPermission()) {
            result.success("granted")
            return
        }
        if (pendingLocalAudioPermissionResult != null) {
            result.error(
                "permission_request_busy",
                "An audio permission request is already pending.",
                null,
            )
            return
        }
        pendingLocalAudioPermissionResult = result
        requestLocalAudioPermissionIfNeeded()
    }

    private fun requestLocalAudioPermissionIfNeeded() {
        if (pendingLocalAudioPermissionResult == null) {
            return
        }
        if (hasAudioLibraryPermission()) {
            completePendingLocalAudioPermission()
            return
        }
        if (localAudioPermissionRequestInFlight ||
            audioPermissionRequestInFlight ||
            notificationPermissionRequestInFlight
        ) {
            return
        }
        localAudioPermissionRequestInFlight = true
        requestPermissions(
            arrayOf(audioLibraryPermission()),
            LOCAL_AUDIO_PERMISSION_REQUEST,
        )
    }

    private fun completePendingLocalAudioPermission() {
        val result = pendingLocalAudioPermissionResult ?: return
        pendingLocalAudioPermissionResult = null
        result.success(localAudioPermissionStatus())
    }

    private fun queryLocalAudioTracks(result: MethodChannel.Result) {
        if (!hasAudioLibraryPermission()) {
            result.error(
                "audio_permission_required",
                "Audio library permission is required.",
                null,
            )
            return
        }
        externalAudioExecutor.execute {
            try {
                val tracks = externalAudioHandler.queryLibrary()
                mainHandler.post { result.success(tracks) }
            } catch (error: Throwable) {
                Log.e(EXTERNAL_AUDIO_TAG, "Could not query the local audio catalog", error)
                mainHandler.post {
                    result.error(
                        "local_audio_query_failed",
                        error.message ?: "Could not query the local audio catalog.",
                        null,
                    )
                }
            }
        }
    }

    private fun loadLocalAudioArtwork(call: MethodCall, result: MethodChannel.Result) {
        if (!hasAudioLibraryPermission()) {
            result.error(
                "audio_permission_required",
                "Audio library permission is required.",
                null,
            )
            return
        }
        val audioUri = call.argument<String>("audioUri")?.trim()
        if (audioUri.isNullOrEmpty()) {
            result.error("invalid_audio_uri", "The audio URI is missing.", null)
            return
        }
        val targetWidth = (call.argument<Number>("targetWidth")?.toInt() ?: 256)
            .coerceIn(32, 1280)
        try {
            localArtworkExecutor.execute {
                try {
                    val bytes = externalAudioHandler.loadArtwork(audioUri, targetWidth)
                    mainHandler.post { result.success(bytes) }
                } catch (error: Throwable) {
                    Log.w(EXTERNAL_AUDIO_TAG, "Could not load local audio artwork", error)
                    mainHandler.post { result.success(null) }
                }
            }
        } catch (error: Throwable) {
            result.error(
                "local_artwork_unavailable",
                error.message ?: "Local artwork is unavailable.",
                null,
            )
        }
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
        if (notificationPermissionRequestInFlight ||
            audioPermissionRequestInFlight ||
            localAudioPermissionRequestInFlight ||
            pendingLocalAudioPermissionResult != null ||
            pendingExternalAudioPermissionRequest != null
        ) {
            return
        }
        notificationPermissionRequestInFlight = true
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
        val messages = generateSequence(this) { it.cause }
            .take(6)
            .mapNotNull { it.message?.trim()?.takeIf(String::isNotEmpty) }
            .distinct()
            .toList()
        // youtubedl-android stores yt-dlp stderr in YoutubeDLException.message.
        // Prefer the deepest cause and keep class names/stack traces in
        // Logcat and MethodChannel details instead of placing them before the
        // useful extractor error on the small player surface. Picking by
        // length can select Exception(Throwable)'s `cause.toString()` wrapper.
        return messages.lastOrNull() ?: "Fallo youtubedl-android"
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
        private const val SCREEN_CHANNEL = "bstream_music/screen"
        private const val SUPPORTED_LINKS_SETTINGS_CHANNEL =
            "bstream_music/supported_links_settings"
        private const val EXTERNAL_AUDIO_CHANNEL = "bstream_music/external_audio"
        private const val APP_ACTIVATION_CHANNEL = "bstream_music/app_activation"
        private const val LOCAL_AUDIO_CHANNEL = "bstream_music/local_audio"
        private const val AUDIO_SERVICE_NOTIFICATION_CLICK_ACTION =
            "com.ryanheise.audioservice.NOTIFICATION_CLICK"
        private const val APP_ACTIVATION_HOME = "home"
        private const val APP_ACTIVATION_PLAYER = "player"
        private val appEntryGeneration = AtomicLong(0)
        private const val NOTIFICATION_PERMISSION_REQUEST = 4010
        private const val FILE_EXPORT_REQUEST = 4011
        private const val EXTERNAL_AUDIO_PERMISSION_REQUEST = 4012
        private const val LOCAL_AUDIO_PERMISSION_REQUEST = 4013
        private const val MAX_PENDING_EXTERNAL_AUDIO_EVENTS = 8
        private const val DEFAULT_SEARCH_RESULT_LIMIT = 20
        private const val MAX_SEARCH_RESULT_LIMIT = 50
        private const val TAG = "BStreamYtdl"
        private const val QUICKJS_LIBRARY_NAME = "libqjs.so"
        private const val QUICKJS_CACHE_DIRECTORY = "bstream_quickjs"
        private const val QUICKJS_DEFAULT_TIMEOUT_MS = 15000L
        private const val QUICKJS_MIN_TIMEOUT_MS = 1000L
        private const val QUICKJS_MAX_TIMEOUT_MS = 60000L
        private const val QUICKJS_OUTPUT_LIMIT = 4 * 1024 * 1024
        private const val QUICKJS_ERROR_LIMIT = 32 * 1024
        private const val EXTERNAL_AUDIO_TAG = "BStreamExternalAudio"
        private const val YTDLP_SHARED_PREFS = "youtubedl-android"
        private const val YTDLP_VERSION_KEY = "dlpVersion"
        private const val YTDLP_VERSION_NAME_KEY = "dlpVersionName"
        private const val BUNDLED_YTDLP_VERSION_KEY = "bstreamBundledYtDlpVersion"
        private const val VERIFIED_YTDLP_VERSION_KEY = "bstreamVerifiedYtDlpVersion"
        private const val VERIFIED_YTDLP_SHA256_KEY = "bstreamVerifiedYtDlpSha256"
        private const val YTDLP_MAX_BINARY_BYTES = 32L * 1024L * 1024L
        private const val YTDLP_CHECKSUM_MANIFEST_MAX_BYTES = 128 * 1024
        private const val YTDLP_CHECKSUM_CONNECT_TIMEOUT_MS = 5000
        private const val YTDLP_CHECKSUM_READ_TIMEOUT_MS = 10000
        private const val YTDLP_UPDATE_FAILURE_COOLDOWN_MS = 2L * 60L * 1000L
        private val YTDLP_CHECKSUM_ALLOWED_HOSTS = setOf(
            "github.com",
            "release-assets.githubusercontent.com",
            "objects.githubusercontent.com",
        )
        private const val PROGRESS_MIN_INTERVAL_MS = 200L
        private const val PROGRESS_MIN_DELTA = 0.01f
        private const val PROGRESS_TEMPLATE =
            "download:BSTREAM_PROGRESS|%(progress._percent_str)s|%(progress.eta)s"
        private const val AUDIO_FORMAT_SELECTOR =
            "bestaudio[ext=m4a]/bestaudio[ext=aac]/bestaudio[acodec^=mp4a]/bestaudio[acodec^=aac]/bestaudio"
        private const val MANAGED_PLAYBACK_DIRECTORY = "bstream_managed_playback"
        private const val MANAGED_PLAYBACK_MAX_FILES = 12
        private const val MANAGED_PLAYBACK_MAX_BYTES = 128L * 1024L * 1024L
        private const val MANAGED_PLAYBACK_MAX_ENTRY_BYTES = 64L * 1024L * 1024L
        private const val MANAGED_PLAYBACK_MAX_AGE_MS = 12L * 60L * 60L * 1000L
        private const val MANAGED_PLAYBACK_PROTECTION_WINDOW = 2
        private const val MANAGED_FILE_PREFIX = "BSTREAM_MANAGED_FILE="
        private const val MANAGED_EXTENSION_PREFIX = "BSTREAM_MANAGED_EXTENSION="
        private const val MANAGED_FORMAT_PREFIX = "BSTREAM_MANAGED_FORMAT="
        private const val MANAGED_CODEC_PREFIX = "BSTREAM_MANAGED_CODEC="
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
            "requested format is not available",
            "format is not supported",
            "no video formats",
            "no se encontró una url reproducible",
            "no se encontro una url reproducible",
        )
        private val RECOVERABLE_EXTRACTOR_ERRORS = listOf(
            "unable to extract",
            "failed to extract",
            "extractor error",
            "signature",
            "nsig",
            "javascript runtime",
            "challenge",
            "http error 403",
            "forbidden",
        )
        private val AUDIO_EXTENSIONS = setOf(
            "3gp",
            "3gpp",
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

    private data class ExternalAudioRequest(
        val id: String,
        val intent: Intent,
        val entryGeneration: Long,
    )

    private data class RuntimeYtDlpVerification(
        val version: String,
        val sha256: String,
    )

    private class ManagedPlaybackSupersededException : IllegalStateException(
        "La preparación fue reemplazada por una pista más reciente.",
    )
}
