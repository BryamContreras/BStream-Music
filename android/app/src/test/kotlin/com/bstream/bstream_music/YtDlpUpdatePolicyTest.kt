package com.bstream.bstream_music

import com.yausername.youtubedl_android.YoutubeDL
import com.yausername.youtubedl_android.YoutubeDLRequest
import java.io.File
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class YtDlpUpdatePolicyTest {
    @Test
    fun `stable is the default release channel`() {
        assertEquals(
            YoutubeDL.UpdateChannel.STABLE,
            YtDlpUpdatePolicy.channel(allowNightly = false),
        )
    }

    @Test
    fun `nightly requires an explicit build opt in`() {
        assertEquals(
            YoutubeDL.UpdateChannel.NIGHTLY,
            YtDlpUpdatePolicy.channel(allowNightly = true),
        )
    }

    @Test
    fun `runtime version must be valid and no older than bundled fallback`() {
        assertTrue(YtDlpUpdatePolicy.isVersionAtLeast("2026.07.04", "2026.07.04"))
        assertTrue(YtDlpUpdatePolicy.isVersionAtLeast("2026.08.01", "2026.07.04"))
        assertTrue(YtDlpUpdatePolicy.isVersionAtLeast("2026.08.01.234500", "2026.08.01"))
        assertFalse(YtDlpUpdatePolicy.isVersionAtLeast("2026.06.30", "2026.07.04"))
        assertFalse(YtDlpUpdatePolicy.isVersionAtLeast("nightly", "2026.07.04"))
        assertFalse(YtDlpUpdatePolicy.isVersionAtLeast("release-2026.08.01", "2026.07.04"))
        assertFalse(YtDlpUpdatePolicy.isVersionAtLeast("2026.02.30", "2026.07.04"))
        assertFalse(
            YtDlpUpdatePolicy.isVersionAtLeast(
                "2026.08.01.99999999999999999999",
                "2026.07.04",
            ),
        )
    }

    @Test
    fun `metadata name tag and executable version must agree`() {
        assertEquals(
            "2026.08.01",
            YtDlpUpdatePolicy.coherentReleaseVersion(
                metadataVersion = "2026.08.01",
                metadataName = "yt-dlp 2026.08.01",
                requiredVersion = "2026.07.04",
            ),
        )
        assertEquals(
            "2026.08.01.234500",
            YtDlpUpdatePolicy.coherentReleaseVersion(
                metadataVersion = "2026.08.01.234500",
                metadataName = "yt-dlp nightly 2026.08.01.234500",
                requiredVersion = "2026.07.04",
            ),
        )
        assertEquals(
            null,
            YtDlpUpdatePolicy.coherentReleaseVersion(
                metadataVersion = "2026.08.01",
                metadataName = "yt-dlp 2026.08.02",
                requiredVersion = "2026.07.04",
            ),
        )
        assertTrue(
            YtDlpUpdatePolicy.executableMatchesRelease("2026.08.01", "2026.08.01"),
        )
        assertFalse(
            YtDlpUpdatePolicy.executableMatchesRelease(
                "yt-dlp 2026.08.01",
                "2026.08.01",
            ),
        )
    }

    @Test
    fun `executable probe can run version without a media URL`() {
        val command = YoutubeDLRequest(emptyList<String>())
            .addOption("--ignore-config")
            .addOption("--version")
            .buildCommand()

        assertEquals(listOf("--ignore-config", "--version"), command)
    }

    @Test
    fun `checksum URL remains on the selected official release repository`() {
        assertEquals(
            "https://github.com/yt-dlp/yt-dlp/releases/download/2026.08.01/SHA2-256SUMS",
            YtDlpUpdatePolicy.checksumManifestUrl(
                YoutubeDL.UpdateChannel.STABLE,
                "2026.08.01",
            ),
        )
        assertEquals(
            "https://github.com/yt-dlp/yt-dlp-nightly-builds/releases/download/" +
                "2026.08.01.234500/SHA2-256SUMS",
            YtDlpUpdatePolicy.checksumManifestUrl(
                YoutubeDL.UpdateChannel.NIGHTLY,
                "2026.08.01.234500",
            ),
        )
        assertEquals(
            null,
            YtDlpUpdatePolicy.checksumManifestUrl(
                YoutubeDL.UpdateChannel.MASTER,
                "2026.08.01",
            ),
        )
    }

    @Test
    fun `checksum manifest requires one exact yt-dlp entry`() {
        val checksum = "a".repeat(64)
        assertEquals(
            checksum,
            YtDlpUpdatePolicy.checksumForAsset(
                "$checksum  yt-dlp\n${"b".repeat(64)}  yt-dlp.exe\n",
            ),
        )
        assertEquals(
            null,
            YtDlpUpdatePolicy.checksumForAsset(
                "$checksum  yt-dlp\n${"b".repeat(64)}  yt-dlp\n",
            ),
        )
        assertEquals(null, YtDlpUpdatePolicy.checksumForAsset("$checksum  ../yt-dlp\n"))
    }

    @Test
    fun `hashing enforces a bounded regular runtime binary`() {
        val file = File.createTempFile("bstream-ytdlp-policy", ".bin")
        try {
            file.writeText("abc")
            assertEquals(
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                YtDlpUpdatePolicy.sha256(file, maximumBytes = 3),
            )
            assertEquals(null, YtDlpUpdatePolicy.sha256(file, maximumBytes = 2))
        } finally {
            file.delete()
        }
    }

    @Test
    fun `failed updates respect a process cooldown`() {
        assertTrue(
            YtDlpUpdatePolicy.canAttemptUpdate(
                nowElapsedMilliseconds = 10_000,
                lastFailureElapsedMilliseconds = null,
                failureCooldownMilliseconds = 5_000,
            ),
        )
        assertFalse(
            YtDlpUpdatePolicy.canAttemptUpdate(
                nowElapsedMilliseconds = 12_000,
                lastFailureElapsedMilliseconds = 10_000,
                failureCooldownMilliseconds = 5_000,
            ),
        )
        assertTrue(
            YtDlpUpdatePolicy.canAttemptUpdate(
                nowElapsedMilliseconds = 15_000,
                lastFailureElapsedMilliseconds = 10_000,
                failureCooldownMilliseconds = 5_000,
            ),
        )
    }
}
