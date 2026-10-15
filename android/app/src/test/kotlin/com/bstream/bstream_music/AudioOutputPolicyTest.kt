package com.bstream.bstream_music

import android.media.AudioDeviceInfo
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AudioOutputPolicyTest {
    @Test fun onlyMediaOutputsAreOffered() {
        assertEquals("speaker", AudioOutputPolicy.type(AudioDeviceInfo.TYPE_BUILTIN_SPEAKER))
        assertEquals("wired", AudioOutputPolicy.type(AudioDeviceInfo.TYPE_WIRED_HEADPHONES))
        assertEquals("bluetooth", AudioOutputPolicy.type(AudioDeviceInfo.TYPE_BLUETOOTH_A2DP))
        assertEquals("bluetooth", AudioOutputPolicy.type(AudioDeviceInfo.TYPE_BLE_HEADSET))
        assertEquals("usb", AudioOutputPolicy.type(AudioDeviceInfo.TYPE_USB_HEADSET))
        assertNull(AudioOutputPolicy.type(AudioDeviceInfo.TYPE_BLUETOOTH_SCO))
        assertNull(AudioOutputPolicy.type(AudioDeviceInfo.TYPE_BUILTIN_EARPIECE))
        assertNull(AudioOutputPolicy.type(AudioDeviceInfo.TYPE_TELEPHONY))
    }

    @Test fun castAllowsActualLanAndWebSources() {
        assertTrue(AudioOutputPolicy.receiverAccessibleUrl("http://192.168.1.5:9301/token/song.mp4"))
        assertTrue(AudioOutputPolicy.receiverAccessibleUrl("https://media.example.com/audio?token=123"))
        assertTrue(AudioOutputPolicy.receiverAccessibleUrl("http://[fd00::2]:8080/song"))
    }

    @Test fun castRejectsPhoneLocalAndInvalidSources() {
        listOf("http://localhost/audio", "http://a.localhost/audio", "http://127.0.0.1/audio",
            "http://127.2.3.4/audio", "http://[::1]/audio", "http://[::]/audio",
            "http://0.0.0.0/audio", "file:///audio.mp4", "content://audio/1", "not a url")
            .forEach { assertFalse(AudioOutputPolicy.receiverAccessibleUrl(it), it) }
    }
}
