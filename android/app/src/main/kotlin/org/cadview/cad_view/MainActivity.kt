package org.cadview.cad_view

import android.app.Activity
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
    companion object {
        private const val PICK_DOCUMENT_REQUEST = 0x4341
        private val CAD_DOCUMENT_MIME_TYPES = arrayOf(
            "application/pdf",
            "image/svg+xml",
            "application/dwg",
            "application/acad",
            "application/x-acad",
            "image/vnd.dwg",
            "application/dxf",
            "application/x-dxf",
            "application/vnd.dxf",
            "image/x-dxf",
            "application/x-dwg",
            "image/x-dwg",
            "image/vnd.dxf",
            "model/stl",
            "application/vnd.ms-pki.stl",
            "application/sla",
            "model/obj",
            "model/gltf+json",
            "model/gltf-binary",
            "model/3mf",
            "application/vnd.ms-package.3dmanufacturing-3dmodel+xml",
            // Providers commonly label ASCII DXF/OBJ, glTF, and binary CAD
            // files with generic types. Dart still validates the extension and
            // Rust probes the bytes after selection.
            "text/plain",
            "application/json",
            "application/octet-stream",
        )
    }

    private val pendingIncomingUris = mutableListOf<Uri>()
    private val incomingLock = Any()
    private var incomingFilesChannel: MethodChannel? = null
    private var pendingDocumentPickerResult: MethodChannel.Result? = null

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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.cadview/document_picker",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickDocument" -> launchDocumentPicker(result)
                else -> result.notImplemented()
            }
        }
        enqueueIncomingIntent(intent, notifyFlutter = false)
    }

    private fun launchDocumentPicker(result: MethodChannel.Result) {
        if (pendingDocumentPickerResult != null) {
            result.error("already_active", "Document picker is already active", null)
            return
        }
        val picker = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, CAD_DOCUMENT_MIME_TYPES)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        if (picker.resolveActivity(packageManager) == null) {
            result.error("picker_unavailable", "No system document picker is available", null)
            return
        }
        pendingDocumentPickerResult = result
        @Suppress("DEPRECATION")
        startActivityForResult(picker, PICK_DOCUMENT_REQUEST)
    }

    @Deprecated("Deprecated in Android")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != PICK_DOCUMENT_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingDocumentPickerResult ?: return
        pendingDocumentPickerResult = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            result.error("missing_document", "The picker did not return a document", null)
            return
        }
        thread(name = "cadview-file-import", isDaemon = true) {
            val path = copyIncomingFile(uri)
            runOnUiThread {
                if (path == null) {
                    result.error("document_import_failed", "Unable to read the selected file", null)
                } else {
                    result.success(path)
                }
            }
        }
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
        val importDirectory = File(File(filesDir, "imports"), UUID.randomUUID().toString())
            .apply { check(mkdirs()) }
        val originalName = queryDisplayName(uri)
            ?: uri.lastPathSegment?.substringAfterLast('/')
            ?: "document"
        val safeName = originalName
            .replace(Regex("[\\\\/\\x00-\\x1f]"), "_")
            .takeUnless { it.isBlank() || it == "." || it == ".." } ?: "document"
        val destination = File(importDirectory, safeName)
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
