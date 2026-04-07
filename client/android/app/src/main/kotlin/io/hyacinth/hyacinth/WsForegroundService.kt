package io.hyacinth.hyacinth

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * M8 — foreground service stub.
 *
 * Hyacinth's WebSocket actually lives in the Dart isolate; this service
 * does not own the socket. Its job is to pin the Android process in the
 * "foreground" state so Doze doesn't throttle the WS heartbeat while the
 * tablet is plugged in and showing a wall dashboard 24/7.
 *
 * The notification is IMPORTANCE_LOW so it doesn't ping the user on
 * install, and the service is explicitly `dataSync` in the manifest so
 * Android 14's foreground-service-type enforcement accepts it.
 *
 * If this service ever grows real responsibilities (e.g. holding the WS
 * itself in a native isolate), the TODOs below mark the hook points.
 */
class WsForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel(this)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notif = buildNotification(this)
        // TODO(M8): if we ever need to own the WS natively, start the
        // connection thread here and surface its state via MethodChannel.
        startForeground(NOTIFICATION_ID, notif)
        return START_STICKY
    }

    override fun onDestroy() {
        // stopForeground(true) equivalent on older APIs — STOP_FOREGROUND_REMOVE
        // is the modern constant.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "hyacinth_ws"
        const val NOTIFICATION_ID = 0x4879 // "Hy"

        fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    val ch = NotificationChannel(
                        CHANNEL_ID,
                        "Hyacinth background",
                        NotificationManager.IMPORTANCE_LOW,
                    ).apply {
                        description = "Keeps Hyacinth running in the background."
                        setShowBadge(false)
                    }
                    nm.createNotificationChannel(ch)
                }
            }
        }

        fun buildNotification(ctx: Context): Notification {
            return NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setContentTitle("Hyacinth")
                .setContentText("Running in the background")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                .build()
        }
    }
}
