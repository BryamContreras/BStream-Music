package com.bstream.bstream_music

import com.yausername.youtubedl_android.YoutubeDL
import java.io.File
import java.security.MessageDigest

/** Restricts runtime extractor updates to known upstream release channels. */
internal object YtDlpUpdatePolicy {
    private val exactDateVersionRegex =
        Regex("(\\d{4})\\.(\\d{1,2})\\.(\\d{1,2})(?:\\.(\\d{1,12}))?")
    private val embeddedDateVersionRegex =
        Regex("(?<!\\d)(\\d{4}\\.\\d{1,2}\\.\\d{1,2}(?:\\.\\d{1,12})?)(?![\\d.])")
    private val checksumLineRegex = Regex("^([0-9a-fA-F]{64})[ \\t]+\\*?(.+?)[ \\t]*$")

    private data class DateVersion(
        val source: String,
        val parts: List<Long>,
    )

    fun channel(allowNightly: Boolean): YoutubeDL.UpdateChannel =
        if (allowNightly) {
            YoutubeDL.UpdateChannel.NIGHTLY
        } else {
            YoutubeDL.UpdateChannel.STABLE
        }

    fun isVersionAtLeast(candidate: String?, required: String): Boolean {
        val candidateParts = parseExactDateVersion(candidate)?.parts ?: return false
        val requiredParts = parseExactDateVersion(required)?.parts ?: return false
        val partCount = maxOf(candidateParts.size, requiredParts.size)
        for (index in 0 until partCount) {
            val candidatePart = candidateParts.getOrElse(index) { 0L }
            val requiredPart = requiredParts.getOrElse(index) { 0L }
            if (candidatePart != requiredPart) {
                return candidatePart > requiredPart
            }
        }
        return true
    }

    /**
     * Validates the release tag and human-readable release name before either
     * value is used to construct a checksum URL.
     */
    fun coherentReleaseVersion(
        metadataVersion: String?,
        metadataName: String?,
        requiredVersion: String,
    ): String? {
        val version = parseExactDateVersion(metadataVersion) ?: return null
        val nameVersion = parseEmbeddedDateVersion(metadataName) ?: return null
        if (!sameVersion(version.parts, nameVersion.parts) ||
            !isVersionAtLeast(version.source, requiredVersion)
        ) {
            return null
        }
        return version.source
    }

    fun executableMatchesRelease(executableVersion: String?, releaseVersion: String): Boolean {
        val executable = parseExactDateVersion(executableVersion) ?: return false
        val release = parseExactDateVersion(releaseVersion) ?: return false
        return sameVersion(executable.parts, release.parts)
    }

    fun checksumManifestUrl(
        channel: YoutubeDL.UpdateChannel,
        releaseVersion: String,
    ): String? {
        val version = parseExactDateVersion(releaseVersion)?.source ?: return null
        val repository = when (channel) {
            YoutubeDL.UpdateChannel.STABLE -> "yt-dlp/yt-dlp"
            YoutubeDL.UpdateChannel.NIGHTLY -> "yt-dlp/yt-dlp-nightly-builds"
            else -> return null
        }
        return "https://github.com/$repository/releases/download/$version/SHA2-256SUMS"
    }

    fun checksumForAsset(manifest: String, assetName: String = "yt-dlp"): String? {
        if (assetName.isBlank()) {
            return null
        }
        var checksum: String? = null
        for (line in manifest.lineSequence()) {
            val match = checksumLineRegex.matchEntire(line) ?: continue
            if (match.groupValues[2] != assetName) {
                continue
            }
            if (checksum != null) {
                return null
            }
            checksum = match.groupValues[1].lowercase()
        }
        return checksum
    }

    fun sha256(file: File, maximumBytes: Long): String? {
        if (!file.isFile || file.length() <= 0L || file.length() > maximumBytes) {
            return null
        }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) {
                    break
                }
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { byte -> "%02x".format(byte) }
    }

    fun canAttemptUpdate(
        nowElapsedMilliseconds: Long,
        lastFailureElapsedMilliseconds: Long?,
        failureCooldownMilliseconds: Long,
    ): Boolean {
        if (lastFailureElapsedMilliseconds == null) {
            return true
        }
        val elapsed = nowElapsedMilliseconds - lastFailureElapsedMilliseconds
        return elapsed < 0L || elapsed >= failureCooldownMilliseconds
    }

    private fun parseEmbeddedDateVersion(value: String?): DateVersion? {
        val matches = embeddedDateVersionRegex.findAll(value?.trim().orEmpty()).toList()
        if (matches.size != 1) {
            return null
        }
        return parseExactDateVersion(matches.single().groupValues[1])
    }

    private fun parseExactDateVersion(value: String?): DateVersion? {
        val source = value?.trim() ?: return null
        val match = exactDateVersionRegex.matchEntire(source) ?: return null
        val year = match.groupValues[1].toLongOrNull() ?: return null
        val month = match.groupValues[2].toLongOrNull() ?: return null
        val day = match.groupValues[3].toLongOrNull() ?: return null
        val revision = match.groupValues[4]
            .takeIf(String::isNotEmpty)
            ?.toLongOrNull()
        if (year < 2000L || month !in 1L..12L || day !in 1L..daysInMonth(year, month)) {
            return null
        }
        if (match.groupValues[4].isNotEmpty() && revision == null) {
            return null
        }
        return DateVersion(
            source = source,
            parts = if (revision == null) {
                listOf(year, month, day)
            } else {
                listOf(year, month, day, revision)
            },
        )
    }

    private fun daysInMonth(year: Long, month: Long): Long = when (month) {
        2L -> if (year % 400L == 0L || (year % 4L == 0L && year % 100L != 0L)) 29L else 28L
        4L, 6L, 9L, 11L -> 30L
        else -> 31L
    }

    private fun sameVersion(left: List<Long>, right: List<Long>): Boolean {
        val partCount = maxOf(left.size, right.size)
        return (0 until partCount).all { index ->
            left.getOrElse(index) { 0L } == right.getOrElse(index) { 0L }
        }
    }
}
