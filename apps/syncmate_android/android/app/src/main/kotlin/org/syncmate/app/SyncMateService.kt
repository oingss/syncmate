package org.syncmate.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/// 前台服务：提高进程优先级，让 HTTP 文件服务与剪切板轮询在后台保持运行。
/// 与 MainActivity 通过 startForegroundService 启动；Dart 侧经
/// MethodChannel 'syncmate/service' 控制（见 docs/platform_channels.md）。
class SyncMateService : Service() {

    override fun onCreate() {
        super.onCreate()
        createChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "SyncMate 后台服务",
                NotificationManager.IMPORTANCE_LOW
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pending = PendingIntent.getActivity(
            this,
            0,
            intent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_IMMUTABLE
            } else {
                0
            }
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SyncMate 正在后台运行")
            .setContentText("文件传输与剪切板同步服务保持在线")
            .setSmallIcon(android.R.drawable.stat_sys_download) // 占位图标，正式图标随打包资源替换
            .setContentIntent(pending)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "syncmate_foreground"
        private const val NOTIFICATION_ID = 1001
    }
}
