package com.example.salamasphere_mobile

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.content.Intent
import androidx.core.content.FileProvider
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.salamasphere/share")
            .setMethodCallHandler { call, result ->
            if (call.method == "shareAudio" || call.method == "shareMedia" ||
                call.method == "viewMedia") {
                val title = call.argument<String>("title") ?: "SalamaSphere evidence"
                val fileName = call.argument<String>("fileName") ?: "salamasphere-evidence"
                val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null || bytes.isEmpty()) {
                    result.error("EMPTY_MEDIA", "No media bytes were supplied.", null)
                    return@setMethodCallHandler
                }
                val safeName = fileName.replace(Regex("[^A-Za-z0-9._-]"), "_")
                val file = File(cacheDir, safeName)
                file.writeBytes(bytes)
                val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                val intent = if (call.method == "viewMedia") {
                    Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, mimeType)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                } else {
                    Intent(Intent.ACTION_SEND).apply {
                        type = mimeType
                        putExtra(Intent.EXTRA_STREAM, uri)
                        putExtra(Intent.EXTRA_SUBJECT, title)
                        putExtra(Intent.EXTRA_TEXT, call.argument<String>("text") ?: title)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }
                }
                try {
                    if (call.method == "viewMedia") {
                        startActivity(intent)
                    } else {
                        startActivity(Intent.createChooser(intent, title))
                    }
                } catch (error: android.content.ActivityNotFoundException) {
                    result.error(
                        "NO_MEDIA_HANDLER",
                        "No installed app can open this media file.",
                        error.message
                    )
                    return@setMethodCallHandler
                }
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method != "shareText") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val text = call.argument<String>("text") ?: ""
                val title = call.argument<String>("title") ?: "SalamaSphere"
                startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_SUBJECT, title)
                    putExtra(Intent.EXTRA_TEXT, text)
                }, title))
                result.success(null)
            }
    }
}
