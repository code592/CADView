package org.cadview.cad_view

import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import kotlin.concurrent.thread

open class CadViewActivityBase : FlutterActivity() {
    private val pendingIncomingUris = mutableListOf<Uri>()
    private val incomingLock = Any()
    private var incomingFilesChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.cadview/native_paths",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "applicationSupportPath" -> result.success(filesDir.absolutePath)
                else -> result.notImplemented()
            }
        }

        incomingFilesChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.cadview/incoming_files",
        ).also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "takePendingFiles" -> importPendingFiles(result)
                    else -> result.notImplemented()
                }
            }
        }
        enqueueIncomingIntent(intent, notifyFlutter = false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        enqueueIncomingIntent(intent, notifyFlutter = true)
    }

    @Suppress("DEPRECATION")
    private fun enqueueIncomingIntent(intent: Intent?, notifyFlutter: Boolean) {
        if (intent == null) return
        val incoming = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let(incoming::add)
            Intent.ACTION_SEND ->
                (intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))?.let(incoming::add)
            Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let(incoming::addAll)
        }
        intent.clipData?.let { clip ->
            for (index in 0 until clip.itemCount) {
                clip.getItemAt(index).uri?.let(incoming::add)
            }
        }
        if (incoming.isEmpty()) return
        synchronized(incomingLock) {
            for (uri in incoming) {
                if (uri !in pendingIncomingUris) pendingIncomingUris.add(uri)
            }
        }
        if (notifyFlutter) {
            incomingFilesChannel?.invokeMethod("incomingFilesAvailable", null)
        }
    }

    private fun importPendingFiles(result: MethodChannel.Result) {
        val uris = synchronized(incomingLock) {
            pendingIncomingUris.toList().also { pendingIncomingUris.clear() }
        }
        if (uris.isEmpty()) {
            result.success(emptyList<String>())
            return
        }
        thread(name = "cadview-file-import", isDaemon = true) {
            val paths = uris.mapNotNull(::copyIncomingFile)
            runOnUiThread { result.success(paths) }
        }
    }

    private fun copyIncomingFile(uri: Uri): String? = runCatching {
        val importDirectory = File(filesDir, "imports").apply { mkdirs() }
        val originalName = queryDisplayName(uri)
            ?: uri.lastPathSegment?.substringAfterLast('/')
            ?: "document"
        val safeName = originalName
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .takeLast(180)
            .ifBlank { "document" }
        val destination = File(
            importDirectory,
            "${System.currentTimeMillis()}_${UUID.randomUUID()}_$safeName",
        )
        val input = requireNotNull(contentResolver.openInputStream(uri)) {
            "Unable to read shared file"
        }
        input.buffered().use { source ->
            destination.outputStream().buffered().use(source::copyTo)
        }
        destination.absolutePath
    }.getOrNull()

    private fun queryDisplayName(uri: Uri): String? = runCatching {
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (!cursor.moveToFirst()) return@use null
            val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (index >= 0) cursor.getString(index) else null
        }
    }.getOrNull()
}
