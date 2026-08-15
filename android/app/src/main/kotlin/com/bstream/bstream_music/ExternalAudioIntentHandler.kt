package com.bstream.bstream_music

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import java.io.File
import java.util.Locale

internal class ExternalAudioIntentHandler(private val context: Context) {
    private val resolver: ContentResolver = context.contentResolver

    fun accepts(intent: Intent?): Boolean {
        if (intent?.action != Intent.ACTION_VIEW || intent.data == null) {
            return false
        }
        val uri = intent.data!!
        val mime = runCatching { intent.type ?: resolver.getType(uri) }
            .getOrNull()
            ?.substringBefore(';')
            ?.trim()
            ?.lowercase(Locale.ROOT)
        if (mime?.startsWith("audio/") == true || mime in APPLICATION_AUDIO_MIME_TYPES) {
            return true
        }
        return uri.lastPathSegment
            ?.substringAfterLast('.', "")
            ?.lowercase(Locale.ROOT) in AUDIO_EXTENSIONS
    }

    fun resolve(
        requestId: String,
        intent: Intent,
        includeFolder: Boolean,
        permissionPending: Boolean,
        permissionDenied: Boolean,
    ): Map<String, Any?> {
        val originalUri = requireNotNull(intent.data)
        val canonicalUri = mediaStoreUri(originalUri)
        val original = querySingle(originalUri) ?: fallbackRow(originalUri)
        val canonical = canonicalUri
            ?.takeUnless { it == originalUri }
            ?.let(::querySingle)
        var selected = mergeSelected(original, canonical)
        if (selected.relativePath == null) {
            selected = selected.copy(relativePath = relativePathFromDocument(originalUri))
        }
        if (selected.absolutePath == null) {
            val absolutePath = if (originalUri.scheme == ContentResolver.SCHEME_FILE) {
                originalUri.path
            } else {
                queryProviderPath(originalUri)
            }
            if (absolutePath != null) {
                selected = selected.copy(
                    absolutePath = absolutePath,
                    relativePath = selected.relativePath
                        ?: relativePathFromAbsolutePath(absolutePath),
                )
            }
        }

        val folderResult = if (includeFolder) {
            queryFolder(selected)
        } else {
            FolderResult(emptyList(), complete = false)
        }
        val queue = folderResult.rows.toMutableList()
        var selectedIndex = queue.indexOfFirst { candidate ->
            sameAudio(candidate, selected, canonicalUri)
        }
        if (selectedIndex >= 0) {
            selected = mergeSelected(selected, queue[selectedIndex])
            queue[selectedIndex] = selected
        } else {
            queue.add(selected)
            queue.sortWith(audioRowComparator)
            selectedIndex = queue.indexOfFirst { it.uri == selected.uri }
        }

        return mapOf(
            "requestId" to requestId,
            "selectedIndex" to selectedIndex.coerceAtLeast(0),
            "folderQueueComplete" to folderResult.complete,
            "permissionPending" to permissionPending,
            "permissionDenied" to permissionDenied,
            "tracks" to queue.map(::toPayload),
        )
    }

    private fun mediaStoreUri(uri: Uri): Uri? {
        if (uri.authority == MediaStore.AUTHORITY) {
            return uri
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val converted = runCatching { MediaStore.getMediaUri(context, uri) }.getOrNull()
            if (converted != null) {
                return converted
            }
        }
        if (uri.authority != MEDIA_DOCUMENTS_AUTHORITY ||
            !DocumentsContract.isDocumentUri(context, uri)
        ) {
            return null
        }
        val documentId = runCatching { DocumentsContract.getDocumentId(uri) }.getOrNull()
            ?: return null
        val pieces = documentId.split(':', limit = 2)
        if (pieces.size != 2 || pieces[0] != "audio") {
            return null
        }
        val id = pieces[1].toLongOrNull() ?: return null
        return ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
    }

    private fun querySingle(uri: Uri): AudioRow? {
        return runCatching {
            resolver.query(uri, null, null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) {
                    return@use null
                }
                rowFromCursor(cursor, uri)
            }
        }.getOrNull()
    }

    private fun fallbackRow(uri: Uri): AudioRow {
        val path = uri.path
        val displayName = path
            ?.substringAfterLast('/')
            ?.takeIf { it.isNotBlank() }
            ?: uri.lastPathSegment
        return AudioRow(
            uri = uri,
            displayName = displayName,
            title = displayName?.substringBeforeLast('.', displayName),
            mimeType = runCatching { resolver.getType(uri) }.getOrNull(),
            absolutePath = if (uri.scheme == ContentResolver.SCHEME_FILE) path else null,
        )
    }

    private fun queryFolder(selected: AudioRow): FolderResult {
        val relativePath = selected.relativePath?.takeIf { it.isNotBlank() }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && relativePath != null) {
            val volume = selected.volumeName ?: MediaStore.VOLUME_EXTERNAL
            val collection = runCatching {
                MediaStore.Audio.Media.getContentUri(volume)
            }.getOrElse { MediaStore.Audio.Media.EXTERNAL_CONTENT_URI }
            return queryCollection(
                collection = collection,
                selection = "${MediaStore.MediaColumns.RELATIVE_PATH} = ?",
                selectionArgs = arrayOf(relativePath),
                expectedParent = null,
            )
        }

        val parent = selected.absolutePath
            ?.let(::File)
            ?.parent
            ?.takeIf { it.isNotBlank() }
            ?: return FolderResult(emptyList(), complete = false)
        return queryCollection(
            collection = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
            selection = "${MediaStore.MediaColumns.DATA} LIKE ?",
            selectionArgs = arrayOf("$parent/%"),
            expectedParent = parent,
        )
    }

    private fun queryCollection(
        collection: Uri,
        selection: String,
        selectionArgs: Array<String>,
        expectedParent: String?,
    ): FolderResult {
        val projection = buildList {
            add(MediaStore.MediaColumns._ID)
            add(MediaStore.MediaColumns.DISPLAY_NAME)
            add(MediaStore.Audio.AudioColumns.TITLE)
            add(MediaStore.Audio.AudioColumns.ARTIST)
            add(MediaStore.Audio.AudioColumns.DURATION)
            add(MediaStore.MediaColumns.MIME_TYPE)
            add(MediaStore.MediaColumns.DATA)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                add(MediaStore.MediaColumns.RELATIVE_PATH)
                add(MediaStore.MediaColumns.VOLUME_NAME)
            }
        }.toTypedArray()

        return try {
            val rows = mutableListOf<AudioRow>()
            resolver.query(
                collection,
                projection,
                selection,
                selectionArgs,
                "${MediaStore.MediaColumns.DISPLAY_NAME} COLLATE NOCASE ASC",
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.longOrNull(MediaStore.MediaColumns._ID) ?: continue
                    val volume = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        cursor.stringOrNull(MediaStore.MediaColumns.VOLUME_NAME)
                    } else {
                        null
                    }
                    val itemCollection = if (
                        Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !volume.isNullOrBlank()
                    ) {
                        MediaStore.Audio.Media.getContentUri(volume)
                    } else {
                        collection
                    }
                    val row = rowFromCursor(
                        cursor,
                        ContentUris.withAppendedId(itemCollection, id),
                    )
                    if (expectedParent == null ||
                        row.absolutePath?.let(::File)?.parent == expectedParent
                    ) {
                        rows.add(row)
                    }
                }
            } ?: return FolderResult(emptyList(), complete = false)
            rows.sortWith(audioRowComparator)
            FolderResult(rows, complete = true)
        } catch (_: Throwable) {
            FolderResult(emptyList(), complete = false)
        }
    }

    private fun rowFromCursor(cursor: Cursor, uri: Uri): AudioRow {
        return AudioRow(
            uri = uri,
            mediaId = cursor.longOrNull(MediaStore.MediaColumns._ID),
            volumeName = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                cursor.stringOrNull(MediaStore.MediaColumns.VOLUME_NAME)
            } else {
                null
            },
            displayName = cursor.stringOrNull(MediaStore.MediaColumns.DISPLAY_NAME),
            title = cursor.stringOrNull(MediaStore.Audio.AudioColumns.TITLE),
            artist = cursor.stringOrNull(MediaStore.Audio.AudioColumns.ARTIST)
                ?.takeUnless { it.equals("<unknown>", ignoreCase = true) },
            durationMs = cursor.longOrNull(MediaStore.Audio.AudioColumns.DURATION)
                ?.takeIf { it > 0L },
            mimeType = cursor.stringOrNull(MediaStore.MediaColumns.MIME_TYPE)
                ?: runCatching { resolver.getType(uri) }.getOrNull(),
            relativePath = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                cursor.stringOrNull(MediaStore.MediaColumns.RELATIVE_PATH)
            } else {
                null
            },
            absolutePath = cursor.stringOrNull(MediaStore.MediaColumns.DATA),
        )
    }

    private fun relativePathFromDocument(uri: Uri): String? {
        if (uri.authority != EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY ||
            !DocumentsContract.isDocumentUri(context, uri)
        ) {
            return null
        }
        val documentId = runCatching { DocumentsContract.getDocumentId(uri) }.getOrNull()
            ?: return null
        val relativeFile = documentId.substringAfter(':', "")
        val parent = relativeFile.substringBeforeLast('/', "")
        return parent.takeIf { it.isNotBlank() }?.let { "$it/" }
    }

    private fun queryProviderPath(uri: Uri): String? {
        val rawPath = runCatching {
            resolver.query(uri, arrayOf(PROVIDER_PATH_COLUMN), null, null, null)?.use { cursor ->
                if (!cursor.moveToFirst()) {
                    return@use null
                }
                cursor.stringOrNull(PROVIDER_PATH_COLUMN)
            }
        }.getOrNull() ?: return null
        val normalized = runCatching { File(rawPath).canonicalPath }.getOrNull()
            ?: rawPath
        return normalized.takeIf(::isSharedStoragePath)
    }

    private fun isSharedStoragePath(path: String): Boolean {
        return path.startsWith("/storage/") ||
            path.startsWith("/sdcard/") ||
            path.startsWith("/mnt/media_rw/")
    }

    private fun relativePathFromAbsolutePath(path: String): String? {
        val normalized = path.replace('\\', '/')
        val relativeFile = when {
            normalized.startsWith("/storage/emulated/0/") ->
                normalized.removePrefix("/storage/emulated/0/")
            normalized.startsWith("/storage/self/primary/") ->
                normalized.removePrefix("/storage/self/primary/")
            normalized.startsWith("/sdcard/") -> normalized.removePrefix("/sdcard/")
            normalized.startsWith("/storage/") ->
                normalized.removePrefix("/storage/").substringAfter('/', "")
            normalized.startsWith("/mnt/media_rw/") ->
                normalized.removePrefix("/mnt/media_rw/").substringAfter('/', "")
            else -> return null
        }
        val parent = relativeFile.substringBeforeLast('/', "")
        return parent.takeIf { it.isNotBlank() }?.let { "$it/" }
    }

    private fun mergeSelected(primary: AudioRow, metadata: AudioRow?): AudioRow {
        if (metadata == null) {
            return primary
        }
        return primary.copy(
            mediaId = metadata.mediaId ?: primary.mediaId,
            volumeName = metadata.volumeName ?: primary.volumeName,
            displayName = primary.displayName ?: metadata.displayName,
            title = primary.title ?: metadata.title,
            artist = primary.artist ?: metadata.artist,
            durationMs = primary.durationMs ?: metadata.durationMs,
            mimeType = primary.mimeType ?: metadata.mimeType,
            relativePath = metadata.relativePath ?: primary.relativePath,
            absolutePath = metadata.absolutePath ?: primary.absolutePath,
        )
    }

    private fun sameAudio(candidate: AudioRow, selected: AudioRow, canonicalUri: Uri?): Boolean {
        if (candidate.uri == selected.uri || candidate.uri == canonicalUri) {
            return true
        }
        if (candidate.mediaId != null &&
            selected.mediaId != null &&
            candidate.mediaId == selected.mediaId &&
            (candidate.volumeName == null ||
                selected.volumeName == null ||
                candidate.volumeName == selected.volumeName)
        ) {
            return true
        }
        if (!candidate.absolutePath.isNullOrBlank() &&
            candidate.absolutePath == selected.absolutePath
        ) {
            return true
        }
        return !candidate.relativePath.isNullOrBlank() &&
            candidate.relativePath == selected.relativePath &&
            !candidate.displayName.isNullOrBlank() &&
            candidate.displayName == selected.displayName
    }

    private fun toPayload(row: AudioRow): Map<String, Any?> {
        val displayName = row.displayName
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: row.uri.lastPathSegment
        val title = row.title
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: displayName?.substringBeforeLast('.', displayName)
            ?: "Audio"
        return mapOf(
            "id" to "external:${row.uri}",
            "uri" to row.uri.toString(),
            "displayName" to displayName,
            "title" to title,
            "artist" to row.artist,
            "durationMs" to row.durationMs,
            "mimeType" to row.mimeType,
        )
    }

    private fun Cursor.stringOrNull(columnName: String): String? {
        val index = getColumnIndex(columnName)
        if (index < 0 || isNull(index)) {
            return null
        }
        return getString(index)?.trim()?.takeIf { it.isNotEmpty() }
    }

    private fun Cursor.longOrNull(columnName: String): Long? {
        val index = getColumnIndex(columnName)
        return if (index < 0 || isNull(index)) null else getLong(index)
    }

    private data class AudioRow(
        val uri: Uri,
        val mediaId: Long? = null,
        val volumeName: String? = null,
        val displayName: String? = null,
        val title: String? = null,
        val artist: String? = null,
        val durationMs: Long? = null,
        val mimeType: String? = null,
        val relativePath: String? = null,
        val absolutePath: String? = null,
    )

    private data class FolderResult(
        val rows: List<AudioRow>,
        val complete: Boolean,
    )

    companion object {
        private const val MEDIA_DOCUMENTS_AUTHORITY =
            "com.android.providers.media.documents"
        private const val EXTERNAL_STORAGE_DOCUMENTS_AUTHORITY =
            "com.android.externalstorage.documents"
        private const val PROVIDER_PATH_COLUMN = "_path"
        private val APPLICATION_AUDIO_MIME_TYPES = setOf(
            "application/ogg",
            "application/x-ogg",
        )
        private val AUDIO_EXTENSIONS = setOf(
            "3gp", "3gpp", "aac", "aiff", "alac", "flac", "m4a", "m4b", "mka", "mp3",
            "mp4", "oga", "ogg", "opus", "vorbis", "wav", "weba", "webm", "wma",
        )
        private val audioRowComparator = compareBy<AudioRow>(
            { (it.displayName ?: it.title ?: it.uri.toString()).lowercase(Locale.ROOT) },
            { it.uri.toString() },
        )
    }
}
