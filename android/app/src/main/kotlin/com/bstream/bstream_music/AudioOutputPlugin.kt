package com.bstream.bstream_music

import android.app.Activity
import android.content.Context
import android.database.ContentObserver
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRouter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.mediarouter.app.SystemOutputSwitcherDialogController
import com.ryanheise.just_audio.BStreamAudioOutput
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.math.roundToInt

/** A media-only bridge. Discovery/volume observers exist only while the sheet is open. */
class AudioOutputPlugin(private val activity: Activity, messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "bstream_music/audio_output")
    private val handler = Handler(Looper.getMainLooper())
    private val audio = activity.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val router = activity.getSystemService(Context.MEDIA_ROUTER_SERVICE) as MediaRouter
    private var watching = false
    private val devicesCallback = object : AudioDeviceCallback() {
        override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>) = emit()
        override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>) {
            val preferred = BStreamAudioOutput.getPreferredDeviceId()
            if (removedDevices.any { it.id == preferred }) {
                BStreamAudioOutput.setPreferredDevice(activity, null)
            }
            emit()
        }
    }
    private val routeCallback = object : MediaRouter.SimpleCallback() {
        override fun onRouteSelected(router: MediaRouter, type: Int, info: MediaRouter.RouteInfo) = emit()
        override fun onRouteChanged(router: MediaRouter, info: MediaRouter.RouteInfo) = emit()
        override fun onRouteVolumeChanged(router: MediaRouter, info: MediaRouter.RouteInfo) = emit()
    }
    private val volumeObserver = object : ContentObserver(handler) {
        override fun onChange(selfChange: Boolean) = emit()
    }

    init { channel.setMethodCallHandler(::handle) }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getState" -> result.success(state())
                "startWatching" -> { startWatching(); result.success(state()) }
                "stopWatching" -> { stopWatching(); result.success(null) }
                "selectRoute" -> {
                    val id = call.argument<String>("id")?.toIntOrNull()
                    if (id == null || !outputs().any { it.id == id }) {
                        result.error("audio_route_unavailable", "The audio output is no longer connected.", null)
                    } else if (BStreamAudioOutput.setPreferredDevice(activity, id)) {
                        emit()
                        result.success(state())
                    } else {
                        result.error("audio_route_unavailable", "Android could not select this audio output.", null)
                    }
                }
                "showSystemPicker" -> {
                    val shown = SystemOutputSwitcherDialogController.showDialog(activity)
                    if (shown) BStreamAudioOutput.setPreferredDevice(activity, null)
                    result.success(shown)
                }
                "setVolume" -> {
                    val volume = call.argument<Number>("volume")?.toDouble()
                        ?: throw IllegalArgumentException("Missing volume")
                    require(volume.isFinite()) { "Volume must be finite" }
                    val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    audio.setStreamVolume(AudioManager.STREAM_MUSIC,
                        (volume.coerceIn(0.0, 1.0) * max).roundToInt(), 0)
                    emit()
                    result.success(state())
                }
                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("audio_output_failed", error.message, null)
        }
    }

    private fun outputs(): List<AudioDeviceInfo> = audio.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
        .filter { deviceType(it.type) != null }
        .distinctBy { it.id }

    private fun deviceType(type: Int): String? = AudioOutputPolicy.type(type)

    internal fun state(): Map<String, Any?> {
        val outputs = outputs()
        val requested = BStreamAudioOutput.getPreferredDeviceId()
            ?.takeIf { id -> outputs.any { it.id == id } }
        val anticipated = if (Build.VERSION.SDK_INT >= 33) {
            audio.getAudioDevicesForAttributes(AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC).build()).map { it.id }.toSet()
        } else emptySet()
        val legacy = router.getSelectedRoute(MediaRouter.ROUTE_TYPE_LIVE_AUDIO)
        val legacyBluetooth = legacy.deviceType == MediaRouter.RouteInfo.DEVICE_TYPE_BLUETOOTH
        val fallback = outputs.firstOrNull { deviceType(it.type) == "bluetooth" && legacyBluetooth }
            ?: outputs.firstOrNull { !legacyBluetooth && deviceType(it.type) in setOf("wired", "usb") }
            ?: outputs.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
        val selectedIds = requested?.let { setOf(it) }
            ?: anticipated.takeIf { it.isNotEmpty() }
            ?: fallback?.let { setOf(it.id) }.orEmpty()
        val max = audio.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        return mapOf(
            "supported" to true,
            "routes" to outputs.map { device -> mapOf(
                "id" to device.id.toString(),
                "name" to device.productName.toString(),
                "type" to deviceType(device.type),
                "selected" to (device.id in selectedIds),
                "selectable" to true,
            ) },
            // An AudioTrack preference is a request, not a guarantee from the HAL.
            "selectionConfirmed" to (requested == null && anticipated.isNotEmpty()),
            "requestedRouteId" to requested?.toString(),
            "volume" to if (max > 0) audio.getStreamVolume(AudioManager.STREAM_MUSIC).toDouble() / max else 0.0,
            "volumeAdjustable" to (!audio.isVolumeFixed && max > 0),
            "hasSystemPicker" to (Build.VERSION.SDK_INT >= 30),
        )
    }

    private fun startWatching() {
        if (watching) return
        watching = true
        audio.registerAudioDeviceCallback(devicesCallback, handler)
        router.addCallback(MediaRouter.ROUTE_TYPE_LIVE_AUDIO, routeCallback)
        activity.contentResolver.registerContentObserver(Settings.System.CONTENT_URI, true, volumeObserver)
    }

    private fun stopWatching() {
        if (!watching) return
        watching = false
        audio.unregisterAudioDeviceCallback(devicesCallback)
        router.removeCallback(routeCallback)
        activity.contentResolver.unregisterContentObserver(volumeObserver)
    }

    private fun emit() { if (watching) channel.invokeMethod("audioOutputChanged", state()) }

    fun dispose() { stopWatching(); channel.setMethodCallHandler(null) }
}
