package com.pocketasr.pocket_asr

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Saves transcript text through Android's system document pickers. */
class TextExportChannel(
    messenger: BinaryMessenger,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val NAME = "pocket_asr/text_export"
        private const val CREATE_DOCUMENT = 7103
        private const val CREATE_DIRECTORY = 7104
    }

    private val channel = MethodChannel(messenger, NAME)
    private var pending: MethodChannel.Result? = null
    private var pendingText: String? = null
    private var pendingFiles: List<Pair<String, String>>? = null

    fun install() {
        channel.setMethodCallHandler(this)
    }

    fun shutdown() {
        pending?.error("export_closed", "Text export was closed", null)
        pending = null
        pendingText = null
        pendingFiles = null
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "saveText" -> saveText(call, result)
            "saveTexts" -> saveTexts(call, result)
            else -> result.notImplemented()
        }
    }

    private fun saveText(call: MethodCall, result: MethodChannel.Result) {
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

    private fun saveTexts(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("export_busy", "A text export is already in progress", null)
            return
        }

        val arguments = call.arguments as? Map<*, *>
        val rawFiles = arguments?.get("files") as? List<*>
        if (rawFiles == null) {
            result.error("invalid_arguments", "Text export arguments are missing", null)
            return
        }
        val files = ArrayList<Pair<String, String>>(rawFiles.size)
        for (raw in rawFiles) {
            val file = raw as? Map<*, *>
            val text = file?.get("text") as? String
            if (text == null) {
                result.error("invalid_text", "Transcript text is missing", null)
                return
            }
            val name = (file["suggestedName"] as? String)
                ?.takeIf(String::isNotBlank)
                ?: "transcript.txt"
            files.add(name to text)
        }
        if (files.isEmpty()) {
            result.success(0)
            return
        }

        pending = result
        pendingFiles = files
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
                )
            }
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, CREATE_DIRECTORY)
        } catch (error: Exception) {
            pending = null
            pendingFiles = null
            result.error("export_failed", error.message ?: error.javaClass.simpleName, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        when (requestCode) {
            CREATE_DOCUMENT -> finishSingle(resultCode, data)
            CREATE_DIRECTORY -> finishBatch(resultCode, data)
            else -> false
        }

    private fun finishSingle(resultCode: Int, data: Intent?): Boolean {
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

    private fun finishBatch(resultCode: Int, data: Intent?): Boolean {
        val result = pending ?: return true
        val files = pendingFiles
        pending = null
        pendingFiles = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        if (files.isNullOrEmpty()) {
            result.success(0)
            return true
        }
        val treeUri = data?.data ?: run {
            result.error("missing_uri", "The selected folder is unavailable", null)
            return true
        }

        try {
            result.success(writeIntoTree(treeUri, files))
        } catch (error: Exception) {
            result.error("export_failed", error.message ?: error.javaClass.simpleName, null)
        }
        return true
    }

    private fun writeIntoTree(treeUri: Uri, files: List<Pair<String, String>>): Int {
        val resolver = activity.contentResolver
        val parentDocumentId = DocumentsContract.getTreeDocumentId(treeUri)
        val parentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, parentDocumentId)
        val used = existingNames(resolver, treeUri, parentDocumentId)
        var saved = 0
        for ((suggestedName, text) in files) {
            val name = uniqueName(sanitizeName(suggestedName), used)
            val documentUri = DocumentsContract.createDocument(
                resolver,
                parentUri,
                "text/plain",
                name,
            ) ?: throw IllegalStateException("Could not create $name")
            val output = resolver.openOutputStream(documentUri, "w")
                ?: throw IllegalStateException("Could not open $name")
            output.use { it.write(text.toByteArray(Charsets.UTF_8)) }
            used.add(name.lowercase())
            saved++
        }
        return saved
    }

    private fun existingNames(
        resolver: ContentResolver,
        treeUri: Uri,
        parentDocumentId: String,
    ): MutableSet<String> {
        val names = mutableSetOf<String>()
        val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentDocumentId)
        resolver.query(
            childrenUri,
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            while (cursor.moveToNext()) {
                cursor.getString(0)?.lowercase()?.let(names::add)
            }
        }
        return names
    }

    /** Keeps a suggested name inside the selected folder and always `.txt`. */
    private fun sanitizeName(name: String): String {
        val cleaned = name
            .replace(Regex("[\\\\/:*?\"<>|\\u0000-\\u001F]"), "_")
            .trim()
        if (cleaned.isEmpty()) return "transcript.txt"
        return if (cleaned.lowercase().endsWith(".txt")) cleaned else "$cleaned.txt"
    }

    /** `note.txt`, `note (2).txt`, …: never overwrite an existing document. */
    private fun uniqueName(name: String, used: MutableSet<String>): String {
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val extension = if (dot > 0) name.substring(dot) else ".txt"
        var candidate = name
        var index = 2
        while (used.contains(candidate.lowercase())) {
            candidate = "$stem ($index)$extension"
            index++
        }
        return candidate
    }
}
