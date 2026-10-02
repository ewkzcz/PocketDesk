package com.pocketdesk.pocketdesk

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.provider.MediaStore
import android.provider.Settings
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

// 生物识别需要 FragmentActivity
class MainActivity : FlutterFragmentActivity() {
    private val io = Executors.newSingleThreadExecutor()

    /** 设备通道：Dart 调用系统能力，点通知打开会话时通知 Dart */
    private var device: MethodChannel? = null

    /** 启动时带来的会话链接，等 Dart 准备好后取走 */
    private var pendingLink: String? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        // 会话链接自己处理，换掉启动意图，避免系统分享插件把它当成分享进来的文字
        pendingLink = linkOf(intent)
        if (pendingLink != null) intent = Intent(Intent.ACTION_MAIN).setClass(this, MainActivity::class.java)
        super.onCreate(savedInstanceState)
        // 待审批与新消息靠系统通知提醒，Android 13 起需在前台时申请一次
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
        }
        KeepAliveService.start(this)
    }

    /** 已在前台或后台时点通知：把链接交给 Dart 打开对应会话（不交给其他插件，以免被当成分享） */
    override fun onNewIntent(intent: Intent) {
        val link = linkOf(intent)
        if (link == null) {
            super.onNewIntent(intent)
            return
        }
        val ch = device
        if (ch == null) pendingLink = link else ch.invokeMethod("open", link)
    }

    /** linkOf：通知或 ntfy 推送带来的 pocketdesk://open 链接 */
    private fun linkOf(intent: Intent?): String? {
        val data = intent?.data ?: return null
        return if (data.scheme == "pocketdesk") data.toString() else null
    }

    override fun onDestroy() {
        KeepAliveService.stop(this)
        super.onDestroy()
    }

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
        val deviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pocketdesk/device")
        device = deviceChannel
        deviceChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeLink" -> {
                    result.success(pendingLink)
                    pendingLink = null
                }
                "alert" -> {
                    alert(call.argument<Boolean>("sound") ?: true)
                    result.success(null)
                }
                "storageRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                "hasAllFiles" -> result.success(hasAllFiles())
                "requestAllFiles" -> {
                    requestAllFiles()
                    result.success(null)
                }
                "notify" -> {
                    notify(call.argument<Int>("id")!!, call.argument<String>("title")!!, call.argument<String>("body")!!, call.argument<Int>("count") ?: 0,
                        call.argument<String>("link") ?: "", call.argument<Boolean>("urgent") ?: false)
                    result.success(null)
                }
                "cancelNotify" -> {
                    val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                    val id = call.argument<Int>("id")
                    if (id == null) nm.cancelAll() else nm.cancel(id)
                    result.success(null)
                }
                "openTailscale" -> {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/tailscale/tailscale-android")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "canInstall" -> result.success(Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls())
                "openInstallSettings" -> {
                    startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    result.success(null)
                }
                "copyImage" -> try {
                    copyImage(File(call.argument<String>("path")!!), call.argument<String>("mime") ?: "image/*")
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
                "clipboardImage" -> io.execute {
                    val path = try { clipboardImage() } catch (e: Exception) { null }
                    runOnUiThread { result.success(path) }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** 是否能读写手机上任意文件夹（Android 11 起需「所有文件访问权限」） */
    private fun hasAllFiles(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    /** 打开系统授权页；旧系统直接弹出存储权限 */
    private fun requestAllFiles() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName")))
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE), 1)
        }
    }

    /**
     * 每个会话一条通知，number 为该会话未读数，桌面图标角标按通知数字累加
     *
     * 处理流程：
     * 1、首次使用时创建通知渠道（待审批单独一个渠道，弹出并响铃），未授权通知时不显示（打开 App 时已申请）
     * 2、点击通知直接打开对应会话，有待审批时弹出审批
     */
    private fun notify(id: Int, title: String, body: String, count: Int, link: String, urgent: Boolean) {
        // 1、渠道与权限
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "消息与完成提醒", NotificationManager.IMPORTANCE_HIGH).apply { setShowBadge(true) })
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && nm.getNotificationChannel(URGENT) == null) {
            nm.createNotificationChannel(NotificationChannel(URGENT, "待审批", NotificationManager.IMPORTANCE_HIGH).apply {
                setShowBadge(true)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 250, 150, 250)
            })
        }
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        // 2、通知
        val target = if (link.isNotEmpty()) Intent(Intent.ACTION_VIEW, Uri.parse(link), this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
            else packageManager.getLaunchIntentForPackage(packageName)
        val open = PendingIntent.getActivity(this, id, target, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        @Suppress("DEPRECATION")
        val b = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) Notification.Builder(this, if (urgent) URGENT else CHANNEL)
            else Notification.Builder(this).setPriority(Notification.PRIORITY_HIGH).setDefaults(Notification.DEFAULT_ALL)
        val n = b.setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setNumber(count)
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(if (urgent) Notification.CATEGORY_REMINDER else Notification.CATEGORY_MESSAGE)
            .build()
        nm.notify(id, n)
    }

    /** alert：App 在前台时的提示音与振动（待审批、任务完成） */
    @Suppress("DEPRECATION")
    private fun alert(sound: Boolean) {
        try {
            if (sound) RingtoneManager.getRingtone(applicationContext, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))?.play()
            val v: Vibrator = if (Build.VERSION.SDK_INT >= 31) (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager).defaultVibrator
                else getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) v.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 200, 120, 200), -1))
            else v.vibrate(longArrayOf(0, 200, 120, 200), -1)
        } catch (e: Exception) {
            // 静音模式或没有振动器时忽略
        }
    }

    /** 把图片以图片形式放进系统剪贴板，可直接粘贴到聊天软件；先复制到缓存目录再授权读取 */
    private fun copyImage(src: File, mime: String) {
        val dir = File(cacheDir, "clip").apply { mkdirs() }
        dir.listFiles()?.forEach { it.delete() }
        val copy = File(dir, src.name)
        src.copyTo(copy, overwrite = true)
        val uri = androidx.core.content.FileProvider.getUriForFile(this, "$packageName.clip", copy)
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        cm.setPrimaryClip(ClipData.newUri(contentResolver, "image", uri))
    }

    /** 剪贴板里的图片复制到缓存目录，返回路径；没有图片时返回 null */
    private fun clipboardImage(): String? {
        val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = cm.primaryClip ?: return null
        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            val type = contentResolver.getType(uri) ?: continue
            if (!type.startsWith("image/")) continue
            val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(type) ?: "png"
            val out = File(cacheDir, "paste/粘贴图片-${System.currentTimeMillis()}.$ext")
            out.parentFile?.mkdirs()
            contentResolver.openInputStream(uri)?.use { input -> out.outputStream().use { input.copyTo(it) } } ?: continue
            return out.absolutePath
        }
        return null
    }

    companion object {
        private const val CHANNEL = "messages"
        private const val URGENT = "approvals"
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
