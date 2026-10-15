package com.bstream.bstream_music

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastDevice
import com.google.android.gms.cast.Cast
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.ConnectionResult
import com.google.android.gms.common.GoogleApiAvailability
import com.google.android.gms.common.images.WebImage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.Executors

/** Native CAF sender; Dart supplies a token-protected LAN URL and owns the music queue. */
class BStreamCastPlugin(context: Context, messenger: BinaryMessenger) {
    private val context = context.applicationContext
    private val channel = MethodChannel(messenger, "bstream_music/cast")
    private val handler = Handler(Looper.getMainLooper())
    private var castContext: CastContext? = null
    private var router: MediaRouter? = null
    private var client: RemoteMediaClient? = null
    private var observedSession: CastSession? = null
    private var discovering = false
    private var discoveryRequested = false
    private var destroyed = false
    private var lastError: String? = null
    private var pendingConnect: MethodChannel.Result? = null
    private var pendingConnectDeviceId: String? = null
    private var pendingLoad: MethodChannel.Result? = null
    private var loadGeneration = 0L
    private var mediaContentId: String? = null
    private val pendingCommands = mutableSetOf<MethodChannel.Result>()
    private var initializationInFlight = false
    private val pendingInitialization = mutableListOf<Pair<MethodCall, MethodChannel.Result>>()
    private val executorDelegate = lazy { Executors.newSingleThreadExecutor() }
    private val initializationExecutor by executorDelegate
    private val playServicesAvailable by lazy {
        GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(context) == ConnectionResult.SUCCESS
    }
    private val selector = MediaRouteSelector.Builder()
        .addControlCategory(CastMediaControlIntent.categoryForCast(
            CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID))
        .build()
    private val routeCallback = object : MediaRouter.Callback() {
        override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) = emit()
        override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) = emit()
        override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = emit()
    }
    private val progressListener = RemoteMediaClient.ProgressListener { _, _ -> emit() }
    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() = emit()
        override fun onMetadataUpdated() = emit()
    }
    private val castListener = object : Cast.Listener() {
        override fun onVolumeChanged() = emit()
        override fun onDeviceNameChanged() = emit()
    }
    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) { lastError = null; emit() }
        override fun onSessionStarted(session: CastSession, sessionId: String) = sessionReady(session)
        override fun onSessionStartFailed(session: CastSession, error: Int) {
            if (pendingConnectDeviceId != null && session.castDevice?.deviceId != null &&
                session.castDevice?.deviceId != pendingConnectDeviceId) return
            sessionFailed(error)
        }
        override fun onSessionEnding(session: CastSession) = emit()
        override fun onSessionEnded(session: CastSession, error: Int) {
            if (observedSession != null && observedSession !== session) { emit(); return }
            observeSession(null)
            // The prior receiver can finish disconnecting after a new route
            // has been selected. It must not cancel that newer connection.
            if (pendingConnectDeviceId != null && session.castDevice?.deviceId != null &&
                pendingConnectDeviceId != session.castDevice?.deviceId) {
                cancelPlayback("cast_disconnected", "The previous Cast session ended.")
            } else cancelPending("cast_disconnected", "The Cast session ended.")
            mediaContentId = null
            emit()
        }
        override fun onSessionResuming(session: CastSession, sessionId: String) = emit()
        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) = sessionReady(session)
        override fun onSessionResumeFailed(session: CastSession, error: Int) = sessionFailed(error)
        override fun onSessionSuspended(session: CastSession, reason: Int) {
            observeSession(null)
            attachClient(null)
            emit()
        }
    }

    init {
        channel.setMethodCallHandler { call, result -> handle(call, result) }
        // A cached audio_service Flutter engine can outlive its Activity. Adopt
        // an existing CAF context/session without starting discovery/init work.
        CastContext.getSharedInstance()?.let(::attachContext)
        if (castContext != null) emit()
    }

    private fun supported(): Boolean = playServicesAvailable

    private fun attachContext(next: CastContext) {
        castContext = next
        router = MediaRouter.getInstance(context)
        next.sessionManager.addSessionManagerListener(sessionListener, CastSession::class.java)
        observeSession(next.sessionManager.currentCastSession)
    }

    private fun initializeFor(call: MethodCall, result: MethodChannel.Result) {
        check(supported()) { "Google Play services is required for Google Cast." }
        pendingInitialization.add(call to result)
        if (initializationInFlight) return
        initializationInFlight = true
        // Loading CAF's dynamite module must not freeze Flutter's UI thread.
        CastContext.getSharedInstance(context, initializationExecutor)
            .addOnSuccessListener { next ->
                initializationInFlight = false
                if (destroyed) return@addOnSuccessListener
                attachContext(next)
                val queued = pendingInitialization.toList()
                pendingInitialization.clear()
                queued.forEach { (method, response) -> handle(method, response, fromInitialization = true) }
            }
            .addOnFailureListener { error ->
                initializationInFlight = false
                if (destroyed) return@addOnFailureListener
                lastError = error.message
                val queued = pendingInitialization.toList()
                pendingInitialization.clear()
                queued.forEach { (_, response) -> response.error("cast_unavailable", error.message, null) }
                emit()
            }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result, fromInitialization: Boolean = false) {
        try {
            if (call.method == "startDiscovery" && !fromInitialization) discoveryRequested = true
            if (call.method == "stopDiscovery") discoveryRequested = false
            if (call.method in setOf("startDiscovery", "connect") && castContext == null) {
                initializeFor(call, result)
                return
            }
            when (call.method) {
                "getState" -> result.success(state())
                "startDiscovery" -> {
                    if (discoveryRequested && !discovering) {
                        discovering = true
                        router!!.addCallback(selector, routeCallback, MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN)
                    }
                    result.success(state())
                }
                "stopDiscovery" -> { stopDiscovery(); result.success(null) }
                "connect" -> connect(call, result)
                "disconnect" -> {
                    castContext?.sessionManager?.endCurrentSession(call.argument<Boolean>("stopPlayback") ?: true)
                    result.success(null)
                }
                "load" -> load(call, result)
                "play" -> command(result) { it.play() }
                "pause" -> command(result) { it.pause() }
                "stop" -> command(result) { it.stop() }
                "seek" -> {
                    val position = (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                    command(result) { it.seek(MediaSeekOptions.Builder().setPosition(position).build()) }
                }
                "setVolume" -> {
                    val volume = call.argument<Number>("volume")?.toDouble()
                        ?: throw IllegalArgumentException("Missing volume")
                    require(volume.isFinite()) { "Volume must be finite" }
                    val session = castContext?.sessionManager?.currentCastSession
                        ?: throw IllegalStateException("No Cast device connected.")
                    session.volume = volume.coerceIn(0.0, 1.0)
                    emit()
                    result.success(state())
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            lastError = error.message
            result.error("cast_failed", error.message, null)
            emit()
        }
    }

    private fun connect(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id")
            ?: throw IllegalArgumentException("Missing Cast device id")
        val route = availableRoutes().firstOrNull { device(it)?.deviceId == id || it.id == id }
            ?: throw IllegalStateException("The Cast device is no longer available.")
        val existing = castContext!!.sessionManager.currentCastSession
        if (existing?.isConnected == true && existing.castDevice?.deviceId == device(route)?.deviceId) {
            observeSession(existing)
            result.success(state())
            return
        }
        pendingConnect?.error("cast_connect_cancelled", "Another Cast device was selected.", null)
        pendingConnect = result
        pendingConnectDeviceId = device(route)?.deviceId
        lastError = null
        route.select()
        handler.postDelayed({
            if (!destroyed && pendingConnect === result) {
                pendingConnect = null
                pendingConnectDeviceId = null
                lastError = "The Cast connection timed out."
                result.error("cast_connect_timeout", lastError, null)
                emit()
            }
        }, 30_000L)
        emit()
    }

    private fun load(call: MethodCall, result: MethodChannel.Result) {
        val remote = requireClient()
        val url = call.argument<String>("url")?.trim().orEmpty()
        require(AudioOutputPolicy.receiverAccessibleUrl(url)) {
            "Cast media must have a receiver-accessible HTTP URL, not phone-local loopback."
        }
        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MUSIC_TRACK).apply {
            putString(MediaMetadata.KEY_TITLE, call.argument<String>("title").orEmpty())
            putString(MediaMetadata.KEY_ARTIST, call.argument<String>("artist").orEmpty())
            val artwork = call.argument<String>("artworkUrl")
            if (!artwork.isNullOrBlank() && Uri.parse(artwork).scheme in setOf("http", "https")) {
                addImage(WebImage(Uri.parse(artwork)))
            }
        }
        val contentId = call.argument<String>("contentId") ?: url
        val builder = MediaInfo.Builder(url)
            .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
            .setContentType(call.argument<String>("mimeType") ?: "audio/mp4")
            .setMetadata(metadata)
            .setCustomData(JSONObject().put("bstreamContentId", contentId))
        val duration = call.argument<Number>("durationMs")?.toLong() ?: 0L
        if (duration > 0L) builder.setStreamDuration(duration)
        val request = MediaLoadRequestData.Builder()
            .setMediaInfo(builder.build())
            .setAutoplay(call.argument<Boolean>("autoplay") ?: true)
            .setCurrentTime((call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L))
            .build()
        pendingLoad?.error("cast_load_cancelled", "Another song was selected.", null)
        pendingLoad = result
        mediaContentId = contentId
        val generation = ++loadGeneration
        lastError = null
        remote.load(request).setResultCallback { response ->
            if (destroyed || generation != loadGeneration || pendingLoad !== result) return@setResultCallback
            pendingLoad = null
            if (response.status.isSuccess) result.success(state())
            else {
                lastError = response.status.statusMessage ?: "The Cast receiver could not load the song (${response.status.statusCode})."
                result.error("cast_load_failed", lastError, response.status.statusCode)
            }
            emit()
        }
        handler.postDelayed({
            if (!destroyed && generation == loadGeneration && pendingLoad === result) {
                pendingLoad = null
                lastError = "The Cast receiver did not finish loading the song."
                result.error("cast_load_timeout", lastError, null)
                emit()
            }
        }, 45_000L)
        emit()
    }

    private fun command(result: MethodChannel.Result,
        action: (RemoteMediaClient) -> com.google.android.gms.common.api.PendingResult<RemoteMediaClient.MediaChannelResult>) {
        val request = action(requireClient())
        pendingCommands.add(result)
        request.setResultCallback { response ->
            if (destroyed) return@setResultCallback
            if (!pendingCommands.remove(result)) return@setResultCallback
            if (response.status.isSuccess) result.success(state())
            else result.error("cast_command_failed", response.status.statusMessage, response.status.statusCode)
            emit()
        }
    }

    private fun requireClient(): RemoteMediaClient {
        check(castContext?.sessionManager?.currentCastSession?.isConnected == true) { "No Cast device connected." }
        return client ?: throw IllegalStateException("The Cast media channel is not ready.")
    }

    private fun sessionReady(session: CastSession) {
        observeSession(session)
        lastError = null
        if (pendingConnectDeviceId != null && pendingConnectDeviceId != session.castDevice?.deviceId) {
            emit()
            return
        }
        val pending = pendingConnect
        pendingConnect = null
        pendingConnectDeviceId = null
        pending?.success(state())
        emit()
    }

    private fun sessionFailed(error: Int) {
        lastError = "Could not connect to the Cast device ($error)."
        observeSession(null)
        cancelPending("cast_connection_failed", lastError!!)
        emit()
    }

    private fun attachClient(next: RemoteMediaClient?) {
        if (client === next) return
        client?.unregisterCallback(mediaCallback)
        client?.removeProgressListener(progressListener)
        client = next
        next?.registerCallback(mediaCallback)
        next?.addProgressListener(progressListener, 1_000L)
    }

    private fun observeSession(next: CastSession?) {
        if (observedSession !== next) {
            observedSession?.removeCastListener(castListener)
            observedSession = next
            next?.addCastListener(castListener)
        }
        attachClient(next?.remoteMediaClient)
    }

    private fun availableRoutes(): List<MediaRouter.RouteInfo> = router?.routes.orEmpty()
        .filter { !it.isDefault && it.isEnabled && it.matchesSelector(selector) && device(it) != null }

    private fun device(route: MediaRouter.RouteInfo): CastDevice? = route.extras?.let(CastDevice::getFromBundle)

    internal fun state(): Map<String, Any?> {
        val session = castContext?.sessionManager?.currentCastSession
        val connected = session?.isConnected == true
        val status = client?.mediaStatus
        val playbackState = when {
            !connected -> "idle"
            pendingLoad != null -> "loading"
            status?.playerState == MediaStatus.PLAYER_STATE_PLAYING -> "playing"
            status?.playerState == MediaStatus.PLAYER_STATE_PAUSED -> "paused"
            status?.playerState == MediaStatus.PLAYER_STATE_BUFFERING -> "loading"
            status?.idleReason == MediaStatus.IDLE_REASON_FINISHED -> "completed"
            else -> "idle"
        }
        val currentDevice = session?.castDevice
        val receiverError = if (pendingLoad == null && status?.idleReason == MediaStatus.IDLE_REASON_ERROR)
            "The Cast receiver could not decode or load the current song." else null
        return mapOf(
            "supported" to supported(),
            "devices" to availableRoutes().map { route ->
                val castDevice = device(route)!!
                mapOf("id" to castDevice.deviceId, "name" to route.name,
                    "address" to castDevice.inetAddress.hostAddress, "type" to "cast")
            }.distinctBy { it["id"] },
            "connected" to connected,
            "connecting" to (pendingConnect != null || session?.isConnecting == true),
            "suspended" to (session?.isSuspended == true),
            "deviceId" to currentDevice?.deviceId,
            "deviceName" to currentDevice?.friendlyName,
            "state" to playbackState,
            "positionMs" to (client?.approximateStreamPosition ?: 0L),
            "durationMs" to (client?.streamDuration ?: 0L),
            "volume" to if (connected) session.volume else 1.0,
            "contentId" to (client?.mediaInfo?.customData?.optString("bstreamContentId")
                ?.takeIf { it.isNotBlank() } ?: mediaContentId),
            "error" to (lastError ?: receiverError),
        )
    }

    private fun emit() { if (!destroyed) channel.invokeMethod("castState", state()) }

    private fun stopDiscovery() {
        if (!discovering) return
        discovering = false
        router?.removeCallback(routeCallback)
    }

    private fun cancelPending(code: String, message: String) {
        pendingConnect?.error(code, message, null)
        pendingConnect = null
        pendingConnectDeviceId = null
        cancelPlayback(code, message)
        pendingInitialization.toList().forEach { (_, response) -> response.error(code, message, null) }
        pendingInitialization.clear()
    }

    private fun cancelPlayback(code: String, message: String) {
        loadGeneration++
        pendingLoad?.error(code, message, null)
        pendingLoad = null
        pendingCommands.toList().forEach { it.error(code, message, null) }
        pendingCommands.clear()
    }

    fun dispose() {
        if (destroyed) return
        stopDiscovery()
        castContext?.sessionManager?.removeSessionManagerListener(sessionListener, CastSession::class.java)
        observeSession(null)
        cancelPending("cast_activity_closed", "The Android activity was closed.")
        destroyed = true
        handler.removeCallbacksAndMessages(null)
        channel.setMethodCallHandler(null)
        if (executorDelegate.isInitialized()) initializationExecutor.shutdown()
    }
}
