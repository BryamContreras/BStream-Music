package com.bstream.bstream_music

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

/** Retains grants only while a bounded copy is made on the document worker. */
object IncomingCsvFileBridge {
    private const val MAX_BYTES = 16L * 1024 * 1024
    private const val HANDLED = "com.bstream.incomingCsvHandled"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    private val pending = linkedMapOf<String, Map<String, Any>>()
    private val owned = mutableMapOf<String, File>()
    private val sources = mutableMapOf<String, String>()
    private val activeSources = mutableSetOf<String>()
    private var channel: MethodChannel? = null
    private var ready = false

    fun attach(messenger: BinaryMessenger) {
        ready = false
        channel = MethodChannel(messenger, "bstream_music/incoming_csv").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        ready = true
                        val opens = pending.values.toList()
                        pending.clear()
                        result.success(opens)
                    }
                    "stop" -> { ready = false; result.success(null) }
                    "release" -> {
                        val id = call.argument<String>("id")
                        val directory = owned.remove(id)
                        sources.remove(id)?.let { activeSources.remove(it) }
                        worker.execute { directory?.deleteRecursively() }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun accept(context: Context, intent: Intent?): Boolean {
        if (intent == null || intent.getBooleanExtra(HANDLED, false) ||
            intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return false
        val uri = when (intent.action) {
            Intent.ACTION_VIEW, Intent.ACTION_EDIT -> intent.data
            Intent.ACTION_SEND -> if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
            }
            else -> null
        } ?: return false
        if (uri.scheme != "content" && uri.scheme != "file") return false
        val mime = intent.type?.lowercase()?.substringBefore(';')
        // Content providers often use numeric URI paths, so MIME is sufficient
        // to start the off-thread displayName check. Unknown files are checked
        // without intercepting the existing audio activation path.
        val csvMime = mime in setOf("text/csv", "text/comma-separated-values", "application/csv", "application/x-csv", "application/vnd.ms-excel")
        val csvPath = uri.lastPathSegment?.lowercase()?.endsWith(".csv") == true
        if (!csvMime && !csvPath && mime !in setOf(null, "application/octet-stream", "text/plain")) return false
        intent.putExtra(HANDLED, true)
        if (!activeSources.add(uri.toString())) return csvMime || csvPath
        val appContext = context.applicationContext
        val id = UUID.randomUUID().toString()
        sources[id] = uri.toString()
        val protectedDirectories = owned.values.map { it.absolutePath }.toSet()
        worker.execute {
            val resolver = appContext.contentResolver
            var name = uri.lastPathSegment?.substringAfterLast('/') ?: "playlist.csv"
            var reportedSize: Long? = null
            try {
                if (uri.scheme == "content") {
                    resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val nameColumn = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (nameColumn >= 0 && !cursor.isNull(nameColumn)) name = cursor.getString(nameColumn)
                            val sizeColumn = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (sizeColumn >= 0 && !cursor.isNull(sizeColumn)) reportedSize = cursor.getLong(sizeColumn)
                        }
                    }
                }
                if (!name.lowercase().endsWith(".csv") && !csvMime) {
                    main.post { sources.remove(id)?.let { activeSources.remove(it) } }
                    return@execute
                }
                require(reportedSize == null || reportedSize!! <= MAX_BYTES) { "CSV exceeds 16 MiB" }
                val sanitizedName = name.substringAfterLast('/').substringAfterLast('\\')
                    .replace(Regex("[\\x00-\\x1f]"), "_").take(180)
                    .takeIf { it.isNotBlank() && it != "." && it != ".." } ?: "playlist.csv"
                val safeName = if (sanitizedName.lowercase().endsWith(".csv")) sanitizedName else "$sanitizedName.csv"
                val root = File(appContext.cacheDir, "incoming-csv")
                // Stale previews are swept only when a new document is opened,
                // never by a timer and never while an active copy is being read.
                root.listFiles()?.filter { it.absolutePath !in protectedDirectories &&
                    it.lastModified() < System.currentTimeMillis() - 24L * 60 * 60 * 1000 }
                    ?.forEach { it.deleteRecursively() }
                val directory = File(root, id).apply { mkdirs() }
                val target = File(directory, safeName)
                try {
                    val input = if (uri.scheme == "file") File(uri.path!!).inputStream() else resolver.openInputStream(uri)
                    requireNotNull(input) { "Cannot read CSV" }.use { source ->
                        target.outputStream().use { output ->
                            val buffer = ByteArray(32 * 1024)
                            var total = 0L
                            while (true) {
                                val count = source.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= MAX_BYTES) { "CSV exceeds 16 MiB" }
                                output.write(buffer, 0, count)
                            }
                        }
                    }
                    main.post {
                        owned[id] = directory
                        publish(id, mapOf("id" to id, "path" to target.absolutePath,
                            "name" to safeName, "source" to uri.toString(), "temporary" to true))
                    }
                } catch (error: Exception) { directory.deleteRecursively(); throw error }
            } catch (error: Exception) {
                main.post {
                    sources.remove(id)?.let { activeSources.remove(it) }
                    publish(id, mapOf("id" to id, "error" to "csv_open_failed", "message" to (error.message ?: "Cannot read CSV")))
                }
            }
        }
        // Opaque octet-stream candidates might be local audio. Only claim the
        // intent when CSV is already known; its off-thread check remains safe.
        return csvMime || csvPath
    }

    private fun publish(id: String, event: Map<String, Any>) {
        pending[id] = event
        val bridge = channel
        if (!ready || bridge == null) return
        bridge.invokeMethod("open", event, object : MethodChannel.Result {
            override fun success(result: Any?) { pending.remove(id) }
            override fun error(code: String, message: String?, details: Any?) = Unit
            override fun notImplemented() = Unit
        })
    }
}
