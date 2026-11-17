package com.bstream.bstream_music

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Keeps widget metadata available while audio_service owns an engine without an Activity. */
class BStreamHomeWidgetEnginePlugin(
    private val workerFactory: () -> ExecutorService = { Executors.newSingleThreadExecutor() },
) : FlutterPlugin {
    interface ActionRelay {
        fun consumePendingAction(): String?
    }

    private var channel: MethodChannel? = null
    private var actionRelay: ActionRelay? = null
    private var actionHandlerReady = false
    private var artworkExecutor: ExecutorService? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        attach(binding.applicationContext, binding.binaryMessenger)
    }

    internal fun attach(context: Context, messenger: BinaryMessenger) {
        check(channel == null) { "The widget bridge is already attached to an engine." }
        val worker = workerFactory()
        artworkExecutor = worker
        channel = MethodChannel(messenger, "bstream_music/home_widget").also { bridge ->
            bridge.setMethodCallHandler { call, result ->
                when (call.method) {
                    "update", "updateArtwork", "updateArtworkBytes" -> {
                        val data = call.arguments as? Map<*, *> ?: emptyMap<String, Any>()
                        // The same bounded serial worker handles UI and headless
                        // updates; bitmap work never blocks Android's main thread.
                        worker.execute {
                            when (call.method) {
                                "update" -> BStreamMusicWidget.update(context, data)
                                "updateArtwork" -> BStreamMusicWidget.updateArtwork(context, data)
                                else -> BStreamMusicWidget.updateArtworkBytes(context, data)
                            }
                        }
                        result.success(null)
                    }
                    "registerActionHandler" -> {
                        actionHandlerReady = true
                        result.success(null)
                    }
                    "consumePendingAction" -> result.success(actionRelay?.consumePendingAction())
                    else -> result.notImplemented()
                }
            }
        }
    }

    fun attachActionRelay(relay: ActionRelay) {
        actionRelay = relay
    }

    fun detachActionRelay(relay: ActionRelay) {
        if (actionRelay === relay) actionRelay = null
    }

    fun sendAction(action: String, onDelivered: () -> Unit) {
        val bridge = channel
        if (bridge == null || !actionHandlerReady) return
        bridge.invokeMethod("widgetAction", action, object : MethodChannel.Result {
            override fun success(result: Any?) = onDelivered()
            override fun error(code: String, message: String?, details: Any?) = Unit
            override fun notImplemented() = Unit
        })
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        detach()
    }

    internal fun detach() {
        channel?.setMethodCallHandler(null)
        channel = null
        actionRelay = null
        actionHandlerReady = false
        artworkExecutor?.shutdown()
        artworkExecutor = null
    }

    companion object {
        fun registerWith(engine: FlutterEngine): BStreamHomeWidgetEnginePlugin {
            val existing = engine.plugins.get(BStreamHomeWidgetEnginePlugin::class.java)
                as? BStreamHomeWidgetEnginePlugin
            if (existing != null) return existing
            return BStreamHomeWidgetEnginePlugin().also { engine.plugins.add(it) }
        }
    }
}
