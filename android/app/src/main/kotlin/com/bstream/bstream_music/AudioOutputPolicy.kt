package com.bstream.bstream_music

import android.media.AudioDeviceInfo
import java.net.URI

internal object AudioOutputPolicy {
    fun type(type: Int): String? = when (type) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
        AudioDeviceInfo.TYPE_WIRED_HEADSET, AudioDeviceInfo.TYPE_WIRED_HEADPHONES -> "wired"
        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_HEARING_AID,
        AudioDeviceInfo.TYPE_BLE_HEADSET, AudioDeviceInfo.TYPE_BLE_SPEAKER -> "bluetooth"
        AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_USB_HEADSET -> "usb"
        AudioDeviceInfo.TYPE_HDMI, AudioDeviceInfo.TYPE_HDMI_ARC,
        AudioDeviceInfo.TYPE_HDMI_EARC, AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> "other"
        else -> null
    }

    fun receiverAccessibleUrl(url: String): Boolean = try {
        val uri = URI(url)
        val host = uri.host?.lowercase()?.removePrefix("[")?.removeSuffix("]").orEmpty()
        uri.scheme?.lowercase() in setOf("http", "https") && host.isNotBlank() &&
            host !in setOf("localhost", "::1", "::", "0.0.0.0") &&
            !host.startsWith("127.") && !host.endsWith(".localhost")
    } catch (_: Exception) { false }
}
