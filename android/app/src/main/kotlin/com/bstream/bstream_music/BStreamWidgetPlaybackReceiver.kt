package com.bstream.bstream_music

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.support.v4.media.MediaBrowserCompat
import android.support.v4.media.session.MediaControllerCompat
import android.support.v4.media.session.MediaSessionCompat
import android.util.Log
import android.view.KeyEvent
import com.ryanheise.audioservice.AudioService
import com.ryanheise.audioservice.AudioServicePlugin

/** Sends widget controls and queue selections to the existing playback engine. */
class BStreamWidgetPlaybackReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent == null) return
        val index: Int?
        val keyCode: Int?
        when (intent.action) {
            ACTION_PLAY_QUEUE_ITEM -> {
                val action = intent.getStringExtra(MainActivity.EXTRA_HOME_WIDGET_ACTION) ?: return
                if (!action.startsWith(MainActivity.HOME_WIDGET_QUEUE_PREFIX)) return
                index = action.removePrefix(MainActivity.HOME_WIDGET_QUEUE_PREFIX)
                    .toIntOrNull()?.takeIf { it >= 0 } ?: return
                keyCode = null
            }
            ACTION_MEDIA_BUTTON -> {
                keyCode = intent.getIntExtra(EXTRA_MEDIA_KEY_CODE, -1)
                    .takeIf { it in MEDIA_KEY_CODES } ?: return
                index = null
            }
            else -> return
        }
        PlaybackRequest(context.applicationContext, index, keyCode, goAsync()).connect()
    }

    private class PlaybackRequest(
        private val context: Context,
        private val index: Int?,
        private val keyCode: Int?,
        private val pending: PendingResult,
    ) : MediaBrowserCompat.ConnectionCallback() {
        private val handler = Handler(Looper.getMainLooper())
        private var finished = false
        private var controller: MediaControllerCompat? = null
        private val browser = MediaBrowserCompat(
            context, ComponentName(context, AudioService::class.java), this, null,
        )
        private val timeout = Runnable { finish() }
        private val callback = object : MediaControllerCompat.Callback() {
            override fun onQueueChanged(queue: MutableList<MediaSessionCompat.QueueItem>?) {
                playWhenReady()
            }

            override fun onSessionDestroyed() = finish()
        }

        fun connect() {
            // A cold media service can connect before Dart has restored its
            // queue. Wait for that publication, without starting an Activity.
            handler.postDelayed(timeout, 8_000)
            try {
                // Reuse audio_service's cached engine. Registration and native
                // MethodChannel handling share this main Looper: the bridge is
                // ready before Dart's first headless widget update is handled.
                BStreamHomeWidgetEnginePlugin.registerWith(
                    AudioServicePlugin.getFlutterEngine(context),
                )
                browser.connect()
            } catch (error: Exception) {
                Log.w(TAG, "Unable to connect widget to playback", error)
                finish()
            }
        }

        override fun onConnected() {
            try {
                controller = MediaControllerCompat(context, browser.sessionToken).also {
                    it.registerCallback(callback, handler)
                }
                if (keyCode != null) {
                    controller?.dispatchMediaButtonEvent(KeyEvent(KeyEvent.ACTION_DOWN, keyCode))
                    finish()
                    return
                }
                playWhenReady()
            } catch (error: Exception) {
                Log.w(TAG, "Unable to select widget queue item", error)
                finish()
            }
        }

        private fun playWhenReady() {
            if (finished) return
            val targetIndex = index ?: return
            val media = controller ?: return
            val queue = media.queue?.takeIf { it.isNotEmpty() } ?: return
            if (targetIndex < queue.size) {
                media.transportControls.skipToQueueItem(queue[targetIndex].queueId)
            }
            finish()
        }

        override fun onConnectionFailed() = finish()

        override fun onConnectionSuspended() = finish()

        private fun finish() {
            if (finished) return
            finished = true
            handler.removeCallbacks(timeout)
            controller?.unregisterCallback(callback)
            browser.disconnect()
            pending.finish()
        }
    }

    companion object {
        private const val TAG = "BStreamWidgetPlayback"
        private const val ACTION_PLAY_QUEUE_ITEM = "com.bstream.bstream_music.WIDGET_QUEUE_PLAY"
        private const val ACTION_MEDIA_BUTTON = "com.bstream.bstream_music.WIDGET_MEDIA_BUTTON"
        private const val EXTRA_MEDIA_KEY_CODE = "media_key_code"
        private val MEDIA_KEY_CODES = setOf(
            KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
            KeyEvent.KEYCODE_MEDIA_PREVIOUS,
            KeyEvent.KEYCODE_MEDIA_NEXT,
        )

        fun mediaButton(context: Context, keyCode: Int): PendingIntent {
            require(keyCode in MEDIA_KEY_CODES)
            val intent = Intent(context, BStreamWidgetPlaybackReceiver::class.java).apply {
                action = ACTION_MEDIA_BUTTON
                putExtra(EXTRA_MEDIA_KEY_CODE, keyCode)
            }
            return PendingIntent.getBroadcast(
                context, keyCode, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
        }

        fun queueClickTemplate(context: Context, appWidgetId: Int): PendingIntent {
            val intent = Intent(context, BStreamWidgetPlaybackReceiver::class.java).apply {
                action = ACTION_PLAY_QUEUE_ITEM
                data = Uri.parse("bstream-widget://queue/$appWidgetId/play")
            }
            val mutableFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else 0
            return PendingIntent.getBroadcast(
                context, 9100 + appWidgetId, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or mutableFlag,
            )
        }
    }
}
