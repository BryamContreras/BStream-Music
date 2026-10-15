package com.ryanheise.just_audio;

import android.content.Context;

/** Public media-device bridge without exposing Media3 types to the host app. */
public final class BStreamAudioOutput {
    private BStreamAudioOutput() {}

    public static Integer getPreferredDeviceId() {
        return AudioPlayer.getBStreamPreferredAudioDeviceId();
    }

    public static boolean setPreferredDevice(Context context, Integer deviceId) {
        return AudioPlayer.setBStreamPreferredAudioDevice(context, deviceId);
    }
}
