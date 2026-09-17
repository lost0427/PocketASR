package com.pocketasr.pocket_asr

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Selects local audio through Android SAF without copying bytes through Flutter. */
class AudioPickerChannel(
    messenger: BinaryMessenger,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "pocket_asr/audio_picker"

        private const val PICK_ONE = 7101
        private const val PICK_MANY = 7102

        private val MIME_TYPES = arrayOf(
            "audio/wav",
            "audio/x-wav",
            "audio/mpeg",
            "audio/mp4",
            "audio/flac",
            "audio/x-flac",
        )
    }

    private val channel = MethodChannel(messenger, NAME)
    private var pending: MethodChannel.Result? = null
    private var pendingRequest = 0

    fun install() {
        channel.setMethodCallHandler(this)
    }

    fun shutdown() {
        pending?.error("picker_closed", "Audio picker was closed", null)
        pending = null
        pendingRequest = 0
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val request = when (call.method) {
            "pickAudio" -> PICK_ONE
            "pickAudios" -> PICK_MANY
            else -> {
                result.notImplemented()
                return
            }
        }
        if (pending != null) {
            result.error("picker_busy", "An audio picker is already open", null)
            return
        }

        pending = result
        pendingRequest = request
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "audio/*"
                putExtra(Intent.EXTRA_MIME_TYPES, MIME_TYPES)
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, request == PICK_MANY)
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                )
            }
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, request)
        } catch (error: Exception) {
            pending = null
            pendingRequest = 0
            result.error("picker_failed", error.message ?: error.javaClass.simpleName, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != PICK_ONE && requestCode != PICK_MANY) return false
        val result = pending ?: return true
        val expectedRequest = pendingRequest
        pending = null
        pendingRequest = 0

        if (requestCode != expectedRequest) {
            result.error("picker_result_mismatch", "Unexpected audio picker result", null)
            return true
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(if (requestCode == PICK_ONE) null else emptyList<Any>())
            return true
        }

        try {
            val uris = LinkedHashSet<Uri>()
            data.data?.let(uris::add)
            data.clipData?.let { clips ->
                for (index in 0 until clips.itemCount) uris.add(clips.getItemAt(index).uri)
            }
            val descriptions = uris.map { describe(it, data.flags) }
            result.success(if (requestCode == PICK_ONE) descriptions.firstOrNull() else descriptions)
        } catch (error: Exception) {
            result.error("picker_failed", error.message ?: error.javaClass.simpleName, null)
        }
        return true
    }

    private fun describe(uri: Uri, resultFlags: Int): Map<String, Any> {
        val resolver = activity.contentResolver
        val takeFlags = resultFlags and Intent.FLAG_GRANT_READ_URI_PERMISSION
        if (takeFlags != 0) {
            runCatching { resolver.takePersistableUriPermission(uri, takeFlags) }
        }

        var name: String? = null
        var size: Long? = null
        val cursor: Cursor? = resolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )
        cursor?.use {
            if (it.moveToFirst()) {
                val nameIndex = it.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex >= 0 && !it.isNull(nameIndex)) name = it.getString(nameIndex)
                val sizeIndex = it.getColumnIndex(OpenableColumns.SIZE)
                if (sizeIndex >= 0 && !it.isNull(sizeIndex)) size = it.getLong(sizeIndex)
            }
        }

        return buildMap {
            put("uri", uri.toString())
            put("name", name?.takeIf(String::isNotBlank) ?: uri.lastPathSegment ?: "audio")
            size?.let { put("size", it) }
        }
    }
}
