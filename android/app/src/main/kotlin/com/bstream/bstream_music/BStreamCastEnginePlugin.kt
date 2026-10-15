package com.bstream.bstream_music

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * CAF session ownership follows audio_service's cached engine, not the visible
 * Activity. Home/Back and Activity recreation must not stop receiver progress
 * or queue-boundary delivery while the Dart relay/music handler still live.
 */
class BStreamCastEnginePlugin : FlutterPlugin {
    private var sender: BStreamCastPlugin? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        sender = BStreamCastPlugin(binding.applicationContext, binding.binaryMessenger)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        sender?.dispose()
        sender = null
    }
}
