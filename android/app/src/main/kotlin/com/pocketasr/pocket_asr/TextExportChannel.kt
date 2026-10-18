package com.pocketasr.pocket_asr

import android.app.Activity
import android.content.Intent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Saves transcript text through Android's system document picker. */
class TextExportChannel(
    messenger: BinaryMessenger,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "pocket_asr/text_export"
        private const val CREATE_DOCUMENT = 7103
    }

    private val channel = MethodChannel(messenger, NAME)
    private var pending: MethodChannel.Result? = null
    private var pendingText: String? = null

    fun install() {
        channel.setMethodCallHandler(this)
    }

    fun shutdown() {
        pending?.error("export_closed", "Text export was closed", null)
        pending = null
        pendingText = null
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "saveText") {
            result.notImplemented()
            return
        }
        if (pending != null) {
            result.error("export_busy", "A text export is already in progress", null)
            return
        }

        val arguments = call.arguments as? Map<*, *>
        if (arguments == null) {
            result.error("invalid_arguments", "Text export arguments are missing", null)
            return
        }
        val text = arguments["text"] as? String
        if (text == null) {
            result.error("invalid_text", "Transcript text is missing", null)
            return
        }
        val suggestedName = (arguments["suggestedName"] as? String)
            ?.takeIf(String::isNotBlank)
            ?: "transcript.txt"

        pending = result
        pendingText = text
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "text/plain"
                putExtra(Intent.EXTRA_TITLE, suggestedName)
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, CREATE_DOCUMENT)
        } catch (error: Exception) {
            pending = null
            pendingText = null
            result.error("export_failed", error.message ?: error.javaClass.simpleName, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != CREATE_DOCUMENT) return false
        val result = pending ?: return true
        val text = pendingText
        pending = null
        pendingText = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(false)
            return true
        }
        if (text == null) {
            result.error("missing_text", "Transcript text is unavailable", null)
            return true
        }
        val uri = data?.data ?: run {
            result.error("missing_uri", "The selected file is unavailable", null)
            return true
        }

        try {
            val output = activity.contentResolver.openOutputStream(uri, "w")
                ?: throw IllegalStateException("Could not open the selected file")
            output.use { it.write(text.toByteArray(Charsets.UTF_8)) }
            result.success(true)
        } catch (error: Exception) {
            result.error("export_failed", error.message ?: error.javaClass.simpleName, null)
        }
        return true
    }
}
