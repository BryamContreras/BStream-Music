package com.bstream.bstream_music

import android.app.Activity
import android.content.Intent
import android.os.Bundle

const val ACTION_OPEN_HOME = "com.bstream.bstream_music.action.OPEN_HOME"

/**
 * A short-lived launcher entry point that always tells the shared Flutter
 * shell to return Home. Android can otherwise foreground an old ACTION_VIEW
 * task without delivering a new intent to MainActivity.
 */
class LauncherActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                action = ACTION_OPEN_HOME
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            },
        )
        finish()
        overridePendingTransition(0, 0)
    }
}
