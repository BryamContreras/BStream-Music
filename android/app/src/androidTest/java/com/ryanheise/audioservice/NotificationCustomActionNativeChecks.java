package com.ryanheise.audioservice;

import android.app.PendingIntent;
import android.content.Context;
import android.os.Build;
import android.support.v4.media.session.PlaybackStateCompat;

import androidx.core.app.NotificationCompat;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Exercises the production pre-33 action factory without starting a service. */
public final class NotificationCustomActionNativeChecks {
    private NotificationCustomActionNativeChecks() {}

    public static int verify(Context context) {
        final FixtureAudioService service = new FixtureAudioService(context);
        final List<PendingIntent> pendingIntents = new ArrayList<>();
        final String[] icons = {
            "bstream_widget_repeat",
            "bstream_notification_repeat_all",
            "bstream_notification_repeat_one",
            "bstream_widget_heart_outline",
            "bstream_widget_heart_filled",
        };
        try {
            NotificationCompat.Action first = null;
            MediaControl firstControl = null;
            for (int index = 0; index < icons.length; index++) {
                final String name = "bstream.native.fixture." + index;
                final String label = "Fixture " + index;
                final MediaControl control = new MediaControl(
                    "drawable/" + icons[index], label, 0,
                    new CustomMediaAction(name, Collections.singletonMap("fixture", index)));
                final NotificationCompat.Action notification = service.createCustomNotificationAction(control);
                pendingIntents.add(notification.actionIntent);
                final PlaybackStateCompat.CustomAction session = service.createCustomAction(control);
                final int expectedIcon = context.getResources().getIdentifier(
                    icons[index], "drawable", context.getPackageName());
                require(expectedIcon != 0, "Missing notification icon: " + icons[index]);
                require(notification.getIconCompat() != null &&
                    notification.getIconCompat().getResId() == expectedIcon, "Legacy icon mismatch");
                require(label.contentEquals(notification.title), "Legacy action lost its translated description");
                require(notification.actionIntent != null, "Legacy custom action has no PendingIntent");
                require(name.equals(session.getAction()), "MediaSession action name mismatch");
                require(session.getExtras() != null && session.getExtras().getInt("fixture") == index,
                    "MediaSession action extras mismatch");
                if (Build.VERSION.SDK_INT >= 31) {
                    require(notification.actionIntent.isImmutable(), "Notification action must be immutable");
                    require(notification.actionIntent.isService(), "Legacy custom action must target the audio service");
                }
                for (int previous = 0; previous < index; previous++) {
                    require(!notification.actionIntent.equals(pendingIntents.get(previous)),
                        "Different custom actions collided in PendingIntent identity");
                }
                if (index == 0) {
                    first = notification;
                    firstControl = control;
                }
            }
            final NotificationCompat.Action replacement = service.createCustomNotificationAction(firstControl);
            require(replacement.actionIntent.equals(first.actionIntent),
                "Updating one custom action changed its PendingIntent identity");
            return icons.length + 1;
        } finally {
            for (PendingIntent pendingIntent : pendingIntents) {
                if (pendingIntent != null) pendingIntent.cancel();
            }
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static final class FixtureAudioService extends AudioService {
        FixtureAudioService(Context context) {
            attachBaseContext(context);
        }
    }
}
