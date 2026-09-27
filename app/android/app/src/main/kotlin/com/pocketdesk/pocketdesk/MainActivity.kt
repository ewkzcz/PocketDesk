package com.pocketdesk.pocketdesk

import android.content.ContentValues
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

// 生物识别需要 FragmentActivity
class MainActivity : FlutterFragmentActivity() {
    private val io = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pocketdesk/downloads").setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(Build.VERSION.SDK_INT >= Build.VERSION_CODES.R)
                "save" -> {
                    val src = call.argument<String>("src")!!
                    val folder = call.argument<String>("folder")!!
                    val name = call.argument<String>("name")!!
                    val mime = call.argument<String>("mime") ?: "application/octet-stream"
                    io.execute {
                        try {
                            val path = saveToDownloads(File(src), folder, name, mime)
                            runOnUiThread { result.success(path) }
                        } catch (e: Exception) {
                            runOnUiThread { result.error("save", e.message, null) }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 通过 MediaStore 写入「下载/PocketDesk/日期/」，不需要存储权限（Android 11 起可按路径读取自己写入的文件）
     *
     * 处理流程：
     * 1、按 name、name-1、name-2 依次找一个目录里还没有的文件名（不区分大小写）
     * 2、先以待定状态插入记录，写入内容后再公开，写一半失败时删除记录
     * 3、返回文件的绝对路径，供 App 内打开
     */
    private fun saveToDownloads(src: File, folder: String, name: String, mime: String): String {
        val rel = Environment.DIRECTORY_DOWNLOADS + "/PocketDesk/" + folder + "/"
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "PocketDesk/$folder")
        val resolver = contentResolver
        val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        // 1、候选名
        val taken = HashSet<String>()
        resolver.query(collection, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), "${MediaStore.MediaColumns.RELATIVE_PATH}=?", arrayOf(rel), null)?.use { c ->
            while (c.moveToNext()) taken.add(c.getString(0).lowercase())
        }
        dir.list()?.forEach { taken.add(it.lowercase()) }
        val dot = name.lastIndexOf('.')
        val (base, ext) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
        var chosen = name
        var i = 1
        while (taken.contains(chosen.lowercase())) {
            chosen = "$base-$i$ext"
            i++
        }
        // 2、写入
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, chosen)
            put(MediaStore.MediaColumns.MIME_TYPE, mime)
            put(MediaStore.MediaColumns.RELATIVE_PATH, rel)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val uri = resolver.insert(collection, values) ?: throw IllegalStateException("无法在下载目录创建文件")
        try {
            resolver.openOutputStream(uri)!!.use { out -> src.inputStream().use { it.copyTo(out) } }
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
        src.delete()
        // 3、路径：系统仍可能因并发改名，以记录里的实际文件名为准
        resolver.query(uri, arrayOf(MediaStore.MediaColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) chosen = c.getString(0)
        }
        return File(dir, chosen).absolutePath
    }
}
