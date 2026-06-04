package com.clementbeal.audio_metadata_reader

import android.app.Activity
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * AudioMetadataReaderPlugin
 *
 * Implements Android-specific permission handling and file access helpers to resolve Scoped Storage
 * access issues. It provides methods to check/request write permission for a content URI,
 * and to open native file descriptors (FD) for content URIs (SAF or MediaStore) so they can be accessed.
 */
class AudioMetadataReaderPlugin: FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.ActivityResultListener {
    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var pendingResult: Result? = null
    private var resolvedUriString: String? = null

    companion object {
        private const val TAG = "AudioMetadataReaderPlugin"
        private const val REQUEST_WRITE_PERMISSION = 1045
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "audio_metadata_reader")
        channel?.setMethodCallHandler(this)
        Log.d(TAG, "onAttachedToEngine: Plugin registered")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = null
        channel?.setMethodCallHandler(null)
        channel = null
        Log.d(TAG, "onDetachedFromEngine: Plugin unregistered")
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "requestWritePermission" -> {
                val uriStr = call.argument<String>("uri")
                if (uriStr == null) {
                    result.error("INVALID_ARGUMENT", "URI is null", null)
                    return
                }
                Log.d(TAG, "onMethodCall requestWritePermission: uri=$uriStr")
                handleRequestWritePermission(uriStr, result)
            }
            "openWritableFileDescriptor" -> {
                val uriStr = call.argument<String>("uri")
                if (uriStr == null) {
                    result.error("INVALID_ARGUMENT", "URI is null", null)
                    return
                }
                Log.d(TAG, "onMethodCall openWritableFileDescriptor: uri=$uriStr")
                handleOpenFileDescriptor(uriStr, "rw", result)
            }
            "openFileDescriptor" -> {
                val uriStr = call.argument<String>("uri")
                val mode = call.argument<String>("mode") ?: "r"
                if (uriStr == null) {
                    result.error("INVALID_ARGUMENT", "URI is null", null)
                    return
                }
                Log.d(TAG, "onMethodCall openFileDescriptor: uri=$uriStr mode=$mode")
                handleOpenFileDescriptor(uriStr, mode, result)
            }
            "commitPickedFile" -> {
                val workingPath = call.argument<String>("workingPath")
                val originalPath = call.argument<String>("originalPath")
                if (workingPath == null || originalPath == null) {
                    result.error("INVALID_ARGUMENT", "workingPath or originalPath is null", null)
                    return
                }
                Log.d(TAG, "onMethodCall commitPickedFile: workingPath=$workingPath, originalPath=$originalPath")
                handleCommitPickedFile(workingPath, originalPath, result)
            }
            "copyContentUriToTemp" -> {
                val uriStr = call.argument<String>("uri")
                val name = call.argument<String>("name")
                if (uriStr == null) {
                    result.error("INVALID_ARGUMENT", "URI is null", null)
                    return
                }
                Log.d(TAG, "onMethodCall copyContentUriToTemp: uri=$uriStr, name=$name")
                handleCopyContentUriToTemp(uriStr, name, result)
            }
            else -> {
                result.notImplemented()
            }
        }
    }

    /**
     * Tries to obtain write permissions for the requested URI.
     * On Android 10+ (Scoped Storage), writing to external files directly is restricted.
     * - First attempts a direct open.
     * - If direct open fails with [android.app.RecoverableSecurityException], redirects user to grant access.
     * - On Android 11+ (API 30+), uses [MediaStore.createWriteRequest] to ask for permission.
     */
    private fun handleRequestWritePermission(uriStr: String, result: Result) {
        val safeContext = context ?: run {
            Log.e(TAG, "handleRequestWritePermission: context is null")
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }

        val originalUri = Uri.parse(uriStr)
        Log.d(TAG, "handleRequestWritePermission: originalUri=$originalUri, authority=${originalUri.authority}")
        if (!originalUri.toString().startsWith("content://")) {
            val filePath = originalUri.toString()
            try {
                val file = File(filePath)
                val writable = file.exists() && file.canWrite()
                Log.d(TAG, "handleRequestWritePermission: local file path=$filePath, writable=$writable")
                result.success(if (writable) filePath else null)
            } catch (e: Exception) {
                Log.e(TAG, "handleRequestWritePermission: failed checking local file: ${e.message}")
                result.success(null)
            }
            return
        }

        // Prefer existing tree/document permissions (e.g. from SAF-selected output directory).
        try {
            safeContext.contentResolver.openFileDescriptor(originalUri, "rw")?.use {
                Log.d(TAG, "handleRequestWritePermission: direct rw open succeeded for $originalUri")
                result.success(originalUri.toString())
                return
            }
        } catch (e: android.app.RecoverableSecurityException) {
            Log.w(TAG, "handleRequestWritePermission: direct rw open hit RecoverableSecurityException for $originalUri: ${e.message}")
        } catch (e: SecurityException) {
            Log.w(TAG, "handleRequestWritePermission: direct rw open denied for $originalUri: ${e.message}")
        } catch (e: Exception) {
            Log.w(TAG, "handleRequestWritePermission: direct rw open failed for $originalUri: ${e.message}")
        }

        // Attempt to resolve the original URI (which might be a Document Provider URI like SAF)
        // to a matching MediaStore URI. If it successfully resolves to a MediaStore URI,
        // we can request explicit write permissions for it via MediaStore APIs.
        val targetUri = resolveToMediaStoreUri(safeContext, originalUri) ?: originalUri
        val targetUriStr = targetUri.toString()
        Log.d(TAG, "handleRequestWritePermission: resolved targetUri=$targetUriStr")

        // ExternalStorageProvider URIs (e.g. SAF Document URIs that could not be resolved to
        // MediaStore) should be writable via SAF tree permissions. If direct open failed
        // and we could not map this to a MediaStore content URI, we refuse per-file write requests.
        if (targetUri.authority == "com.android.externalstorage.documents") {
            Log.w(TAG, "handleRequestWritePermission: refusing per-file write request for SAF tree uri=$targetUri")
            result.success(null)
            return
        }

        if (checkUriPermission(targetUri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
            Log.d(TAG, "handleRequestWritePermission: Already has write permission for $targetUriStr")
            result.success(targetUriStr)
            return
        }

        // Try opening in "rw" mode to verify access.
        try {
            safeContext.contentResolver.openFileDescriptor(targetUri, "rw")?.use {
                Log.d(TAG, "handleRequestWritePermission: Successfully opened in 'rw' mode, returning $targetUriStr")
                result.success(targetUriStr)
                return
            }
        } catch (e: android.app.RecoverableSecurityException) {
            Log.d(TAG, "handleRequestWritePermission: RecoverableSecurityException caught, launching userAction intent")
            val safeActivity = activity ?: run {
                Log.e(TAG, "handleRequestWritePermission: activity is null for RecoverableSecurityException")
                result.error("NO_ACTIVITY", "Activity is null, cannot request write permission", null)
                return
            }
            pendingResult = result
            resolvedUriString = targetUriStr
            try {
                safeActivity.startIntentSenderForResult(
                    e.userAction.actionIntent.intentSender,
                    REQUEST_WRITE_PERMISSION,
                    null,
                    0,
                    0,
                    0
                )
            } catch (launchError: Exception) {
                pendingResult = null
                resolvedUriString = null
                Log.e(TAG, "handleRequestWritePermission: failed launching RecoverableSecurityException intent: ${launchError.message}")
                result.error("WRITE_PERMISSION_FAILED", launchError.message, null)
            }
            return
        } catch (e: SecurityException) {
            Log.w(TAG, "handleRequestWritePermission: SecurityException during 'rw' open check: ${e.message}")
        } catch (e: Exception) {
            Log.w(TAG, "handleRequestWritePermission: Exception during 'rw' open check: ${e.message}")
        }

        // Android 11+ MediaStore.createWriteRequest fallback.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && targetUri.authority == "media") {
            Log.d(TAG, "handleRequestWritePermission: API 30+, using MediaStore.createWriteRequest")
            val safeActivity = activity ?: run {
                Log.e(TAG, "handleRequestWritePermission: activity is null for MediaStore.createWriteRequest")
                result.error("NO_ACTIVITY", "Activity is null, cannot request write permission", null)
                return
            }
            try {
                val uris = listOf(targetUri)
                val pendingIntent = MediaStore.createWriteRequest(safeContext.contentResolver, uris)
                pendingResult = result
                resolvedUriString = targetUriStr
                safeActivity.startIntentSenderForResult(
                    pendingIntent.intentSender,
                    REQUEST_WRITE_PERMISSION,
                    null,
                    0,
                    0,
                    0
                )
            } catch (e: Exception) {
                Log.e(TAG, "handleRequestWritePermission: MediaStore.createWriteRequest failed: ${e.message}")
                result.error("WRITE_PERMISSION_FAILED", e.message, null)
            }
        } else {
            Log.w(TAG, "handleRequestWritePermission: Not a media store URI or SDK < 30, and open check failed. No permission available.")
            if (checkUriPermission(targetUri, Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
                result.success(targetUriStr)
            } else {
                result.success(null)
            }
        }
    }

    /**
     * Opens the file descriptor for the given content URI.
     * Returns the integer File Descriptor (FD) to the Dart caller.
     */
    private fun handleOpenFileDescriptor(uriStr: String, mode: String, result: Result) {
        val safeContext = context ?: run {
            Log.e(TAG, "handleOpenFileDescriptor: context is null")
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }

        val targetUri = Uri.parse(uriStr)
        Log.d(TAG, "handleOpenFileDescriptor: targetUri=$targetUri mode=$mode")

        try {
            safeContext.contentResolver.openFileDescriptor(targetUri, mode)?.use { pfd ->
                val fd = pfd.detachFd()
                Log.d(TAG, "handleOpenFileDescriptor: opened fd=$fd for $uriStr")
                result.success(fd)
                return
            }
            Log.e(TAG, "handleOpenFileDescriptor: openFileDescriptor returned null for $uriStr")
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "handleOpenFileDescriptor: failed to open fd for $uriStr: ${e.message}", e)
            result.success(null)
        }
    }

    private fun handleCommitPickedFile(workingPath: String, originalPath: String, result: Result) {
        val safeContext = context ?: run {
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }
        val workingFile = File(workingPath)
        if (!workingFile.exists()) {
            result.error("MISSING_WORKING_FILE", "Working file does not exist", null)
            return
        }

        if (!originalPath.startsWith("content://")) {
            try {
                val originalFile = File(originalPath)
                workingFile.copyTo(originalFile, overwrite = true)
                result.success(null)
            } catch (e: Exception) {
                result.error("COMMIT_FAILED", e.message, null)
            }
            return
        }

        try {
            val originalUri = Uri.parse(originalPath)
            val destUri = resolveToMediaStoreUri(safeContext, originalUri) ?: originalUri
            Log.d(TAG, "handleCommitPickedFile: writing to $destUri (resolved from $originalPath)")
            safeContext.contentResolver.openOutputStream(destUri, "rwt")?.use { outputStream ->
                workingFile.inputStream().use { inputStream ->
                    inputStream.copyTo(outputStream)
                }
            }
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "handleCommitPickedFile: failed writing to uri $originalPath: ${e.message}", e)
            result.error("COMMIT_FAILED", e.message, null)
        }
    }

    private fun handleCopyContentUriToTemp(uriStr: String, name: String?, result: Result) {
        val safeContext = context ?: run {
            result.error("INTERNAL_ERROR", "Context is null", null)
            return
        }
        val uri = Uri.parse(uriStr)
        val fileName = name ?: "temp_audio"
        try {
            val tempFile = File(safeContext.cacheDir, "picked_${System.currentTimeMillis()}_$fileName")
            safeContext.contentResolver.openInputStream(uri)?.use { inputStream ->
                tempFile.outputStream().use { outputStream ->
                    inputStream.copyTo(outputStream)
                }
            }
            result.success(tempFile.absolutePath)
        } catch (e: Exception) {
            Log.e(TAG, "handleCopyContentUriToTemp: failed copying $uriStr: ${e.message}", e)
            result.error("COPY_FAILED", e.message, null)
        }
    }

    private fun resolveToMediaStoreUri(context: Context, uri: Uri): Uri? {
        if (uri.authority == "media") {
            return uri
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT && DocumentsContract.isDocumentUri(context, uri)) {
            val docId = DocumentsContract.getDocumentId(uri)
            Log.d(TAG, "resolveToMediaStoreUri: isDocumentUri, docId=$docId")
            if (docId != null) {
                val parts = docId.split(":")
                if (parts.size == 2) {
                    val type = parts[0]
                    val id = parts[1].toLongOrNull()
                    if (id != null) {
                        Log.d(TAG, "resolveToMediaStoreUri: docId matches specific MediaStore ID type=$type, id=$id")
                        if (type.equals("audio", ignoreCase = true)) {
                            return ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                        } else if (type.equals("video", ignoreCase = true)) {
                            return ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
                        } else if (type.equals("image", ignoreCase = true)) {
                            return ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                        }
                    }
                }

                if (docId.startsWith("primary:", ignoreCase = true)) {
                    val relPath = docId.substring("primary:".length)
                    val fullPath = "/storage/emulated/0/$relPath"
                    Log.d(TAG, "resolveToMediaStoreUri: primary storage path relPath=$relPath, fullPath=$fullPath")

                    val scannedUri = scanFileSynchronously(context, fullPath)
                    if (scannedUri != null) {
                        return scannedUri
                    }

                    return resolvePathToMediaStoreUri(context, fullPath)
                }
            }
        }
        return null
    }

    private fun scanFileSynchronously(context: Context, filePath: String): Uri? {
        val latch = CountDownLatch(1)
        var resultUri: Uri? = null
        try {
            MediaScannerConnection.scanFile(context, arrayOf(filePath), null) { path, uri ->
                Log.d(TAG, "scanFile Callback: path=$path, uri=$uri")
                resultUri = uri
                latch.countDown()
            }
            val completed = latch.await(3, TimeUnit.SECONDS)
            if (!completed) {
                Log.w(TAG, "scanFileSynchronously: Media scanner timed out for $filePath")
            }
        } catch (e: Exception) {
            Log.e(TAG, "scanFileSynchronously error: ${e.message}", e)
        }
        return resultUri
    }

    private fun resolvePathToMediaStoreUri(context: Context, filePath: String): Uri? {
        val projection = arrayOf(MediaStore.Audio.Media._ID)
        val selection = "${MediaStore.Audio.Media.DATA} = ?"
        val selectionArgs = arrayOf(filePath)
        try {
            context.contentResolver.query(
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI,
                projection,
                selection,
                selectionArgs,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
                    val id = cursor.getLong(idIndex)
                    return ContentUris.withAppendedId(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, id)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "resolvePathToMediaStoreUri: failed querying audio MediaStore: ${e.message}")
        }

        try {
            val fileProjection = arrayOf(MediaStore.Files.FileColumns._ID)
            val fileSelection = "${MediaStore.Files.FileColumns.DATA} = ?"
            val fileSelectionArgs = arrayOf(filePath)
            val externalUri = MediaStore.Files.getContentUri("external")
            context.contentResolver.query(
                externalUri,
                fileProjection,
                fileSelection,
                fileSelectionArgs,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idIndex = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
                    val id = cursor.getLong(idIndex)
                    return ContentUris.withAppendedId(externalUri, id)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "resolvePathToMediaStoreUri: failed querying files MediaStore: ${e.message}")
        }
        return null
    }

    private fun checkUriPermission(uri: Uri, modeFlags: Int): Boolean {
        val safeContext = context ?: return false
        return try {
            safeContext.checkUriPermission(
                uri,
                android.os.Process.myPid(),
                android.os.Process.myUid(),
                modeFlags
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } catch (e: Exception) {
            false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == REQUEST_WRITE_PERMISSION) {
            val result = pendingResult
            val uriStr = resolvedUriString
            pendingResult = null
            resolvedUriString = null
            Log.d(TAG, "onActivityResult: requestCode=$requestCode, resultCode=$resultCode")
            if (result != null) {
                if (resultCode == Activity.RESULT_OK) {
                    Log.d(TAG, "onActivityResult: Permission GRANTED, returning $uriStr")
                    result.success(uriStr)
                } else {
                    Log.w(TAG, "onActivityResult: Permission DENIED, returning null")
                    result.success(null)
                }
                return true
            }
        }
        return false
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        Log.d(TAG, "onAttachedToActivity: Activity attached")
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
        Log.d(TAG, "onDetachedFromActivityForConfigChanges")
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addActivityResultListener(this)
        Log.d(TAG, "onReattachedToActivityForConfigChanges")
    }

    override fun onDetachedFromActivity() {
        activity = null
        Log.d(TAG, "onDetachedFromActivity: Activity detached")
    }
}
