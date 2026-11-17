package com.bstream.bstream_music

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Build
import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.StandardMethodCodec
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.AbstractExecutorService
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit

/** Exercises the headless channel without launching an Activity or sending playback commands. */
internal object HomeWidgetBridgeNativeChecks {
    fun verify(base: Context): Int {
        val directory = File(base.cacheDir, "home_widget_bridge_native_checks").apply { mkdirs() }
        val context = FixtureContext(base, directory)
        val prefs = context.getSharedPreferences("bstream_home_widget", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        try {
            return verifyHeadlessUpdates(context, directory, prefs) +
                verifyChannelLifecycle(context) + verifyMediaButtonTemplates(base)
        } finally {
            prefs.edit().clear().commit()
            listOf(
                "bstream_widget_cover.jpg",
                "bstream_widget_cover_alternate.jpg",
                "bstream_widget_cover.jpg.tmp",
                "bstream_widget_cover_alternate.jpg.tmp",
                "source.png",
            ).forEach { File(directory, it).delete() }
        }
    }

    private fun verifyHeadlessUpdates(
        context: Context,
        directory: File,
        prefs: SharedPreferences,
    ): Int {
        val worker = ManualExecutor()
        val messenger = FixtureMessenger()
        val plugin = BStreamHomeWidgetEnginePlugin(workerFactory = { worker })
        plugin.attach(context, messenger)
        try {
            check(messenger.activeHandlers == 1) { "Headless widget channel was not attached" }
            val source = File(directory, "source.png").apply { writeBytes(imageBytes(Color.BLUE)) }
            messenger.invoke("update", metadata("first", "First song"))
            messenger.invoke(
                "updateArtworkBytes",
                mapOf("trackId" to "first", "bytes" to imageBytes(Color.RED)),
            )
            messenger.invoke("update", metadata("next", "Next song"))
            messenger.invoke(
                "updateArtwork",
                mapOf("trackId" to "next", "artworkPath" to source.path),
            )
            check(worker.pendingCount == 4 && !prefs.contains("trackId")) {
                "Widget channel performed serialized metadata/artwork work inline"
            }
            worker.runNext()
            check(prefs.getString("title", null) == "First song") {
                "Headless update did not publish the restored song"
            }
            worker.runNext()
            check(prefs.getBoolean("hasCover", false)) { "Headless artwork bytes were not saved" }
            check(File(directory, "bstream_widget_cover.jpg").isFile)
            worker.runNext()
            check(prefs.getString("trackId", null) == "next" &&
                prefs.getString("title", null) == "Next song") {
                "Headless Next did not replace the widget metadata"
            }
            worker.runNext()
            check(prefs.getInt("coverSlot", -1) == 1 &&
                File(directory, "bstream_widget_cover_alternate.jpg").isFile) {
                "Headless artwork path did not follow its metadata update"
            }
            check(worker.pendingCount == 0 && messenger.activeHandlers == 1)
        } finally {
            plugin.detach()
        }
        check(worker.isShutdown() && messenger.activeHandlers == 0)
        return 4
    }

    private fun verifyChannelLifecycle(context: Context): Int {
        val workers = mutableListOf<ManualExecutor>()
        val plugin = BStreamHomeWidgetEnginePlugin(workerFactory = {
            ManualExecutor().also { workers.add(it) }
        })
        val first = FixtureMessenger()
        val relay = PendingRelay("favorite")
        var delivered = 0
        plugin.attach(context, first)
        try {
            plugin.attachActionRelay(relay)
            plugin.sendAction("repeat") { delivered++ }
            check(first.outbound.isEmpty() && delivered == 0) {
                "Widget action was delivered before Dart registered its handler"
            }
            first.invoke("registerActionHandler")
            check(first.invoke("consumePendingAction") == "favorite")
            check(first.invoke("consumePendingAction") == null) {
                "Pending widget action was delivered more than once"
            }
            plugin.sendAction("repeat") { delivered++ }
            check(first.outbound.single().method == "widgetAction" &&
                first.outbound.single().arguments == "repeat" && delivered == 1)
            plugin.detach()
            check(first.activeHandlers == 0 && workers.single().isShutdown()) {
                "Detached headless bridge retained its channel or worker"
            }

            val second = FixtureMessenger()
            plugin.attach(context, second)
            check(workers.size == 2 && !workers.last().isShutdown())
            check(first.activeHandlers == 0 && second.activeHandlers == 1) {
                "Reattached bridge registered more than one native handler"
            }
            plugin.sendAction("favorite") { delivered++ }
            check(second.outbound.isEmpty() && delivered == 1) {
                "Reattached bridge inherited the old Dart readiness flag"
            }
            check(second.invoke("consumePendingAction") == null) {
                "Reattached bridge retained its previous Activity relay"
            }
            second.invoke("registerActionHandler")
            plugin.sendAction("favorite") { delivered++ }
            check(second.outbound.single().arguments == "favorite" && delivered == 2)
            second.invoke("update", metadata("reattached", "Reattached song"))
            workers.last().runNext()
        } finally {
            plugin.detach()
        }
        check(workers.all { it.isShutdown() })
        return 3
    }

    private fun verifyMediaButtonTemplates(context: Context): Int {
        val keys = listOf(
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_NEXT,
        )
        keys.forEach { key ->
            val pending = BStreamWidgetPlaybackReceiver.mediaButton(context, key)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                check(pending.isBroadcast && pending.isImmutable && !pending.isActivity) {
                    "Widget media key $key must use an immutable broadcast without an Activity"
                }
            }
            // These are the same tokens used by installed widgets. Do not send
            // or cancel them: inspecting the factory must leave playback usable.
        }
        return keys.size
    }

    private fun metadata(id: String, title: String) = mapOf(
        "trackId" to id,
        "title" to title,
        "artist" to "Headless bridge fixture",
        "isPlaying" to true,
        "queueJson" to "[]",
    )

    private fun imageBytes(color: Int): ByteArray {
        val bitmap = Bitmap.createBitmap(8, 8, Bitmap.Config.ARGB_8888)
        return try {
            bitmap.eraseColor(color)
            ByteArrayOutputStream().use { output ->
                check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, output))
                output.toByteArray()
            }
        } finally {
            bitmap.recycle()
        }
    }

    private class FixtureContext(base: Context, private val directory: File) : ContextWrapper(base) {
        override fun getApplicationContext(): Context = this
        override fun getFilesDir(): File = directory
        // AppWidgetManager verifies package ownership. Keep the actual package;
        // preferences/files are isolated and the runner restores launcher views.
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
            super.getSharedPreferences(
                if (name == "bstream_home_widget") "bstream_home_widget_native_bridge_checks" else name,
                mode,
            )
    }

    private class PendingRelay(private var pending: String?) : BStreamHomeWidgetEnginePlugin.ActionRelay {
        override fun consumePendingAction(): String? = pending.also { pending = null }
    }

    private class ManualExecutor : AbstractExecutorService() {
        private val tasks = ArrayDeque<Runnable>()
        private var stopped = false
        val pendingCount: Int get() = tasks.size
        override fun execute(command: Runnable) {
            if (stopped) throw RejectedExecutionException("Fixture executor has shut down")
            tasks.addLast(command)
        }
        fun runNext() = tasks.removeFirst().run()
        override fun shutdown() { stopped = true }
        override fun shutdownNow(): MutableList<Runnable> {
            stopped = true
            return tasks.toMutableList().also { tasks.clear() }
        }
        override fun isShutdown(): Boolean = stopped
        override fun isTerminated(): Boolean = stopped && tasks.isEmpty()
        override fun awaitTermination(timeout: Long, unit: TimeUnit): Boolean = isTerminated()
    }

    private class FixtureMessenger : BinaryMessenger {
        private val codec = StandardMethodCodec.INSTANCE
        private val handlers = mutableMapOf<String, BinaryMessenger.BinaryMessageHandler>()
        val outbound = mutableListOf<MethodCall>()
        val activeHandlers: Int get() = handlers.size
        override fun setMessageHandler(channel: String, handler: BinaryMessenger.BinaryMessageHandler?) {
            if (handler == null) handlers.remove(channel) else handlers[channel] = handler
        }
        override fun send(channel: String, message: ByteBuffer?) = send(channel, message, null)
        override fun send(channel: String, message: ByteBuffer?, callback: BinaryMessenger.BinaryReply?) {
            check(channel == CHANNEL && message != null)
            outbound.add(codec.decodeMethodCall(readable(message)))
            callback?.reply(readable(codec.encodeSuccessEnvelope(null)))
        }
        fun invoke(method: String, arguments: Any? = null): Any? {
            val handler = handlers[CHANNEL] ?: error("No native home widget handler")
            var replied = false
            var result: ByteBuffer? = null
            handler.onMessage(readable(codec.encodeMethodCall(MethodCall(method, arguments)))) { response ->
                replied = true
                result = response
            }
            check(replied && result != null) { "Widget method $method did not acknowledge its call" }
            return codec.decodeEnvelope(readable(result!!))
        }
        private fun readable(buffer: ByteBuffer): ByteBuffer = buffer.duplicate().apply { flip() }
    }

    private const val CHANNEL = "bstream_music/home_widget"
}
