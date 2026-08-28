package com.localchat.local_chat

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log

/**
 * Keeps a large send running while the app is not on screen.
 *
 * Holding the Tailscale tunnel open is not enough on its own: seconds after the
 * last window goes away Android may freeze the process, and a frozen process
 * uploads nothing. A foreground service is the only supported way to say "this
 * work is for the user and is still going", and the notification it requires is
 * what the user wants anyway — visible progress on a file that takes minutes, and
 * a way to stop it.
 */
class UploadService : Service() {

    private var lastPercent: Int = -1
    private var lastDrawnAtMs: Long = 0L

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL -> {
                cancelRequested = true
                // The send itself notices and stops. Until it does, say so: a
                // notification still counting up makes Cancel look ignored.
                promote(cancellingNotice())
                lastPercent = -1
                lastDrawnAtMs = System.currentTimeMillis()
            }
            ACTION_STOP -> {
                stopNow()
                return START_NOT_STICKY
            }
            else -> {
                running = true
                val sent = intent?.getLongExtra(EXTRA_SENT, 0L) ?: 0L
                val total = intent?.getLongExtra(EXTRA_TOTAL, 0L) ?: 0L
                val percent = UploadNoticePolicy.percent(sent, total)
                val now = System.currentTimeMillis()
                val first = lastDrawnAtMs == 0L
                if (first ||
                    UploadNoticePolicy.shouldRedraw(lastPercent, percent, lastDrawnAtMs, now)
                ) {
                    promote(
                        progressNotice(
                            title = intent?.getStringExtra(EXTRA_TITLE),
                            sent = sent,
                            total = total,
                            count = intent?.getIntExtra(EXTRA_COUNT, 1) ?: 1,
                            percent = percent,
                        )
                    )
                    lastPercent = percent
                    lastDrawnAtMs = now
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        super.onDestroy()
    }

    private fun stopNow() {
        running = false
        lastPercent = -1
        lastDrawnAtMs = 0L
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun promote(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Never let the wrapper break the thing it wraps: if Android refuses
            // the promotion the upload still runs, it just loses its protection
            // from being frozen.
            Log.w(TAG, "Could not show the upload notice: $e")
        }
    }

    private fun progressNotice(
        title: String?,
        sent: Long,
        total: Long,
        count: Int,
        percent: Int,
    ): Notification =
        newBuilder()
            .setContentTitle(UploadNoticePolicy.title(title, count))
            .setContentText(UploadNoticePolicy.progressLine(sent, total))
            .setProgress(100, percent, total <= 0L)
            .also { builder ->
                @Suppress("DEPRECATION")
                builder.addAction(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "Cancel",
                    servicePendingIntent(ACTION_CANCEL),
                )
            }
            .build()

    private fun cancellingNotice(): Notification =
        newBuilder()
            .setContentTitle("Stopping the send")
            .setContentText("Finishing the piece already on its way…")
            .setProgress(0, 0, true)
            .build()

    @Suppress("DEPRECATION")
    private fun newBuilder(): Notification.Builder {
        ensureChannel(this)
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this).setPriority(Notification.PRIORITY_LOW)
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return builder
            .setSmallIcon(R.drawable.ic_stat_notification)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
    }

    private fun servicePendingIntent(action: String): PendingIntent =
        PendingIntent.getService(
            this,
            action.hashCode(),
            Intent(this, UploadService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    companion object {
        private const val TAG = "UploadService"
        const val CHANNEL_ID = "local_chat_uploads"
        const val NOTIFICATION_ID = 8121

        const val ACTION_PROGRESS = "com.localchat.local_chat.UPLOAD_PROGRESS"
        const val ACTION_CANCEL = "com.localchat.local_chat.UPLOAD_CANCEL"
        const val ACTION_STOP = "com.localchat.local_chat.UPLOAD_STOP"

        const val EXTRA_TITLE = "title"
        const val EXTRA_SENT = "sent"
        const val EXTRA_TOTAL = "total"
        const val EXTRA_COUNT = "count"

        /** Set when the user taps Cancel; the Dart side reads this and stops. */
        @Volatile
        var cancelRequested: Boolean = false
            private set

        @Volatile
        var running: Boolean = false
            private set

        fun clearCancel() {
            cancelRequested = false
        }

        /**
         * Show or update the sending notice.
         *
         * Always called while a window is up — a send starts from a tap — which
         * is what makes starting a foreground service permitted on modern
         * Android.
         */
        fun show(
            context: Context,
            title: String?,
            sent: Long,
            total: Long,
            count: Int = 1,
        ) {
            deliver(
                context,
                Intent(context, UploadService::class.java)
                    .setAction(ACTION_PROGRESS)
                    .putExtra(EXTRA_TITLE, title)
                    .putExtra(EXTRA_SENT, sent)
                    .putExtra(EXTRA_TOTAL, total)
                    .putExtra(EXTRA_COUNT, count),
            )
        }

        fun stop(context: Context) {
            clearCancel()
            deliver(
                context,
                Intent(context, UploadService::class.java).setAction(ACTION_STOP),
            )
        }

        private fun deliver(context: Context, intent: Intent) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // A refused start must not take the upload with it.
                Log.w(TAG, "Could not reach the upload service: $e")
            }
        }

        fun ensureChannel(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
            val manager = context.getSystemService(NotificationManager::class.java) ?: return
            if (manager.getNotificationChannel(CHANNEL_ID) != null) return
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Sending attachments",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Progress while a photo, video, or file is being sent."
                    setShowBadge(false)
                    enableVibration(false)
                }
            )
        }
    }
}
