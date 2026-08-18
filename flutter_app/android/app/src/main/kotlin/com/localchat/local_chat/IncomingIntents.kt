package com.localchat.local_chat

import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import java.io.File

/// Turns an Android share (or a tapped localchat:// link) into a plain map the
/// Dart side can act on.
///
/// Shared media arrives as a content:// URI owned by the sending app, and that
/// permission dies with the activity, so every attachment is copied into our own
/// cache here and handed over as a real file path.
object IncomingIntents {
    const val CHANNEL = "local_chat/incoming"

    private const val TAG = "IncomingIntents"

    /// Cap per share, matching the app's own album limit.
    private const val MAX_FILES = 50

    fun parse(context: Context, intent: Intent?): Map<String, Any?>? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_SEND -> parseSend(context, intent)
            Intent.ACTION_SEND_MULTIPLE -> parseSendMultiple(context, intent)
            Intent.ACTION_VIEW -> parseView(intent)
            else -> null
        }
    }

    private fun parseSend(context: Context, intent: Intent): Map<String, Any?>? {
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
            ?: intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val stream = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        val files = if (stream == null) emptyList() else copyAll(context, listOf(stream))
        if (text.isNullOrBlank() && files.isEmpty()) return null
        return shareMap(text = text, subject = subject, files = files)
    }

    private fun parseSendMultiple(context: Context, intent: Intent): Map<String, Any?>? {
        val streams = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            ?: return null
        val files = copyAll(context, streams.filterNotNull())
        if (files.isEmpty()) return null
        return shareMap(
            text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString(),
            subject = intent.getStringExtra(Intent.EXTRA_SUBJECT),
            files = files,
        )
    }

    private fun parseView(intent: Intent): Map<String, Any?>? {
        val data = intent.data ?: return null
        if (data.scheme != "localchat") return null
        return mapOf("kind" to "link", "uri" to data.toString())
    }

    private fun shareMap(
        text: String?,
        subject: String?,
        files: List<Map<String, Any?>>,
    ): Map<String, Any?> = mapOf(
        "kind" to "share",
        "text" to text,
        "subject" to subject,
        "files" to files,
    )

    private fun copyAll(context: Context, uris: List<Uri>): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        for (uri in uris.take(MAX_FILES)) {
            val copied = copyToCache(context, uri)
            if (copied != null) out.add(copied)
        }
        return out
    }

    private fun copyToCache(context: Context, uri: Uri): Map<String, Any?>? {
        val resolver = context.contentResolver
        return try {
            val name = displayName(resolver, uri)
            val dir = File(context.cacheDir, "shared_in").apply { mkdirs() }
            // Prefixed with a timestamp so two shares of the same file name in one
            // session cannot overwrite each other mid-upload.
            val target = File(dir, "${System.currentTimeMillis()}_$name")
            resolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            if (target.length() == 0L) {
                target.delete()
                return null
            }
            mapOf(
                "path" to target.absolutePath,
                "name" to name,
                "mime" to resolver.getType(uri),
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not copy shared file: ${e.message}")
            null
        }
    }

    private fun displayName(resolver: ContentResolver, uri: Uri): String {
        var name: String? = null
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (column >= 0) name = cursor.getString(column)
                    }
                }
        } catch (e: Exception) {
            Log.w(TAG, "No display name for $uri: ${e.message}")
        }
        val fallback = uri.lastPathSegment?.substringAfterLast('/')
        val chosen = name ?: fallback ?: "shared"
        // Path separators in a provider-supplied name would escape the cache dir.
        return chosen.replace(Regex("[\\\\/]"), "_").ifBlank { "shared" }
    }
}
