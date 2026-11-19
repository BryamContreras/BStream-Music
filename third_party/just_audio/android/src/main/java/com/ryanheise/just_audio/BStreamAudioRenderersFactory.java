package com.ryanheise.just_audio;

import android.content.Context;
import android.media.AudioFormat;
import android.media.AudioTrack;
import android.media.MediaFormat;
import android.os.Handler;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.common.util.Util;
import androidx.media3.exoplayer.DefaultRenderersFactory;
import androidx.media3.exoplayer.Renderer;
import androidx.media3.exoplayer.audio.AudioRendererEventListener;
import androidx.media3.exoplayer.audio.AudioSink;
import androidx.media3.exoplayer.audio.DefaultAudioSink;
import androidx.media3.exoplayer.audio.MediaCodecAudioRenderer;
import androidx.media3.exoplayer.mediacodec.MediaCodecSelector;
import java.util.ArrayList;

/** Requests float decoding only when the extractor reports high precision. */
final class BStreamAudioRenderersFactory extends DefaultRenderersFactory {
    private final BStreamEqualizerConfiguration equalizer;
    private BStreamEqualizerAudioSink sink;

    BStreamAudioRenderersFactory(Context context, BStreamEqualizerConfiguration equalizer) {
        super(context);
        this.equalizer = equalizer;
        setEnableAudioFloatOutput(true);
    }

    @Override
    protected AudioSink buildAudioSink(
            Context context, boolean enableFloatOutput, boolean enableAudioTrackPlaybackParams) {
        AudioSink delegate = new DefaultAudioSink.Builder(context)
                .setAudioProcessorChain(new BStreamAudioProcessorChain(equalizer))
                .setEnableFloatOutput(enableFloatOutput)
                .setEnableAudioTrackPlaybackParams(enableAudioTrackPlaybackParams)
                .build();
        sink = new BStreamEqualizerAudioSink(
                delegate, equalizer, enableFloatOutput, BStreamAudioRenderersFactory::acceptsFloat);
        return sink;
    }

    @Override
    protected void buildAudioRenderers(
            Context context, int extensionRendererMode, MediaCodecSelector codecSelector,
            boolean enableDecoderFallback, AudioSink audioSink, Handler handler,
            AudioRendererEventListener listener, ArrayList<Renderer> out) {
        out.add(new MediaCodecAudioRenderer(context, getCodecAdapterFactory(), codecSelector,
                enableDecoderFallback, handler, listener, audioSink) {
            @Override
            protected MediaFormat getMediaFormat(
                    Format format, String codecMime, int maxInputSize, float operatingRate) {
                MediaFormat mediaFormat = super.getMediaFormat(
                        format, codecMime, maxInputSize, operatingRate);
                if (!Util.isEncodingHighResolutionPcm(format.pcmEncoding)
                        && mediaFormat.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                    mediaFormat.setInteger(MediaFormat.KEY_PCM_ENCODING, C.ENCODING_PCM_16BIT);
                }
                return mediaFormat;
            }
        });
    }

    boolean setPlaybackProcessing(boolean skipSilence, PlaybackParameters parameters) {
        return sink != null && sink.setPlaybackProcessing(skipSilence, parameters);
    }

    private static boolean acceptsFloat(Format format) {
        int channelConfig = Util.getAudioTrackChannelConfig(format.channelCount);
        return channelConfig != AudioFormat.CHANNEL_INVALID && AudioTrack.getMinBufferSize(
                format.sampleRate, channelConfig, C.ENCODING_PCM_FLOAT) > 0;
    }
}
