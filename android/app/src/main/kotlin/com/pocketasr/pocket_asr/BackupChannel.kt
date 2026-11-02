package com.pocketasr.pocket_asr

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.zip.Deflater
import java.util.zip.ZipEntry
import java.util.zip.ZipInputStream
import java.util.zip.ZipOutputStream

/** Streams the backup archive to and from Android's system document pickers. */
class BackupChannel(
    messenger: BinaryMessenger,
    private val activity: Activity,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val NAME = "pocket_asr/backup"
        const val PROGRESS = "pocket_asr/backup_progress"
        private const val CREATE_ARCHIVE = 7105
        private const val OPEN_ARCHIVE = 7106
        private const val MAX_ENTRIES = 10000
        private const val MAX_BYTES = 16L * 1024 * 1024 * 1024
        private val ALLOWED = Regex(
            "^(manifest\\.json|db/pocket_asr\\.sqlite|models/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+)\$",
        )
    }

    private val main = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, NAME)
    private val progressChannel = EventChannel(messenger, PROGRESS)
    private var pending: MethodChannel.Result? = null
    private var pendingEntries: List<Pair<String, String>>? = null
    private var pendingTotal = 0L
    private var pendingStaging: String? = null
    private var sink: EventChannel.EventSink? = null
    private var lastProgressAt = 0L

    fun install() {
        channel.setMethodCallHandler(this)
        progressChannel.setStreamHandler(this)
    }

    fun shutdown() {
        pending?.error("backup_closed", "Backup was closed", null)
        pending = null
        pendingEntries = null
        pendingStaging = null
        sink = null
        channel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "exportZip" -> exportZip(call, result)
            "importZip" -> importZip(call, result)
            else -> result.notImplemented()
        }
    }

    private fun exportZip(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("backup_busy", "A backup is already in progress", null)
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val rawEntries = arguments?.get("entries") as? List<*>
        if (rawEntries == null || rawEntries.isEmpty()) {
            result.error("invalid_arguments", "Backup entries are missing", null)
            return
        }
        val entries = ArrayList<Pair<String, String>>(rawEntries.size)
        for (raw in rawEntries) {
            val entry = raw as? Map<*, *>
            val name = entry?.get("name") as? String
            val path = entry?.get("path") as? String
            if (name == null || path == null || !ALLOWED.matches(name)) {
                result.error("invalid_arguments", "Backup entry is invalid", null)
                return
            }
            if (!File(path).isFile) {
                result.error("missing_file", "Backup source file is missing", null)
                return
            }
            entries.add(name to path)
        }
        pending = result
        pendingEntries = entries
        pendingTotal = (arguments?.get("totalBytes") as? Number)?.toLong() ?: 0L
        val suggested = (arguments?.get("suggestedName") as? String)
            ?.takeIf(String::isNotBlank)
            ?: "pocketasr-backup.zip"
        try {
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "application/zip"
                putExtra(Intent.EXTRA_TITLE, suggested)
            }
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, CREATE_ARCHIVE)
        } catch (error: Exception) {
            clearPending()
            result.error("backup_failed", error.message ?: error.javaClass.simpleName, null)
        }
    }

    private fun importZip(call: MethodCall, result: MethodChannel.Result) {
        if (pending != null) {
            result.error("backup_busy", "A backup is already in progress", null)
            return
        }
        val arguments = call.arguments as? Map<*, *>
        val staging = (arguments?.get("stagingDirectory") as? String)
            ?.takeIf(String::isNotBlank)
        if (staging == null) {
            result.error("invalid_arguments", "Backup staging directory is missing", null)
            return
        }
        pending = result
        pendingStaging = staging
        try {
            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            }
            @Suppress("DEPRECATION")
            activity.startActivityForResult(intent, OPEN_ARCHIVE)
        } catch (error: Exception) {
            clearPending()
            result.error("backup_failed", error.message ?: error.javaClass.simpleName, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
        when (requestCode) {
            CREATE_ARCHIVE -> finishExport(resultCode, data)
            OPEN_ARCHIVE -> finishImport(resultCode, data)
            else -> false
        }

    private fun finishExport(resultCode: Int, data: Intent?): Boolean {
        val result = pending ?: return true
        val entries = pendingEntries
        val total = pendingTotal
        clearPending()
        if (resultCode != Activity.RESULT_OK) {
            result.success(false)
            return true
        }
        val uri = data?.data ?: run {
            result.error("missing_uri", "The selected file is unavailable", null)
            return true
        }
        if (entries == null) {
            result.error("missing_entries", "Backup entries are unavailable", null)
            return true
        }
        Thread {
            try {
                writeArchive(uri, entries, total)
                main.post { result.success(true) }
            } catch (error: Exception) {
                main.post {
                    result.error(
                        "backup_failed",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
        }.start()
        return true
    }

    private fun finishImport(resultCode: Int, data: Intent?): Boolean {
        val result = pending ?: return true
        val staging = pendingStaging
        clearPending()
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        val uri = data?.data ?: run {
            result.error("missing_uri", "The selected file is unavailable", null)
            return true
        }
        if (staging == null) {
            result.error("missing_staging", "Backup staging directory is unavailable", null)
            return true
        }
        Thread {
            try {
                extractArchive(uri, File(staging))
                main.post { result.success(staging) }
            } catch (error: Exception) {
                runCatching { File(staging).deleteRecursively() }
                main.post {
                    result.error(
                        "backup_failed",
                        error.message ?: error.javaClass.simpleName,
                        null,
                    )
                }
            }
        }.start()
        return true
    }

    private fun writeArchive(uri: Uri, entries: List<Pair<String, String>>, total: Long) {
        val resolver = activity.contentResolver
        val output = resolver.openOutputStream(uri, "w")
            ?: throw IllegalStateException("Could not open the selected file")
        output.use { raw ->
            BufferedOutputStream(raw).use { buffered ->
                ZipOutputStream(buffered).use { zip ->
                    zip.setLevel(Deflater.NO_COMPRESSION)
                    var done = 0L
                    val buffer = ByteArray(256 * 1024)
                    for ((name, path) in entries) {
                        zip.putNextEntry(ZipEntry(name))
                        FileInputStream(path).use { input ->
                            while (true) {
                                val read = input.read(buffer)
                                if (read < 0) break
                                zip.write(buffer, 0, read)
                                done += read
                                emitProgress("export", done, total)
                            }
                        }
                        zip.closeEntry()
                    }
                    zip.finish()
                }
            }
        }
    }

    private fun extractArchive(uri: Uri, staging: File) {
        staging.deleteRecursively()
        staging.mkdirs()
        val root = staging.canonicalPath + File.separator
        val resolver = activity.contentResolver
        val input = resolver.openInputStream(uri)
            ?: throw IllegalStateException("Could not open the selected file")
        input.use { raw ->
            BufferedInputStream(raw).use { buffered ->
                ZipInputStream(buffered).use { zip ->
                    val buffer = ByteArray(256 * 1024)
                    var entries = 0
                    var total = 0L
                    while (true) {
                        val entry = zip.nextEntry ?: break
                        entries++
                        if (entries > MAX_ENTRIES) {
                            throw IllegalStateException("Backup has too many entries")
                        }
                        val name = entry.name.replace('\\', '/')
                        if (!ALLOWED.matches(name)) {
                            throw IllegalStateException("Unsupported backup entry: $name")
                        }
                        val target = File(staging, name)
                        if (!target.canonicalPath.startsWith(root)) {
                            throw IllegalStateException("Unsafe backup entry: $name")
                        }
                        target.parentFile?.mkdirs()
                        target.outputStream().use { output ->
                            while (true) {
                                val read = zip.read(buffer)
                                if (read < 0) break
                                total += read
                                if (total > MAX_BYTES) {
                                    throw IllegalStateException("Backup is too large")
                                }
                                output.write(buffer, 0, read)
                                emitProgress("import", total, 0)
                            }
                        }
                        zip.closeEntry()
                    }
                }
            }
        }
    }

    private fun emitProgress(phase: String, done: Long, total: Long) {
        val now = System.currentTimeMillis()
        if (done != total && now - lastProgressAt < 100) return
        lastProgressAt = now
        main.post {
            sink?.success(
                mapOf("phase" to phase, "done" to done, "total" to total),
            )
        }
    }

    private fun clearPending() {
        pending = null
        pendingEntries = null
        pendingStaging = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }
}
