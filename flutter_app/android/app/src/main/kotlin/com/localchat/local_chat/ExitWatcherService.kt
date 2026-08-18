package com.localchat.local_chat

import android.app.Service
import android.content.Intent
import android.os.IBinder

/**
 * Exists only to hear [onTaskRemoved], which is Android's one reliable signal
 * that the user swiped Local Chat out of Recents.
 *
 * Declared with `android:stopWithTask="false"` so the system delivers that
 * callback instead of silently discarding the service with the task.
 */
class ExitWatcherService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_STICKY

    override fun onTaskRemoved(rootIntent: Intent?) {
        TailscaleExit.disconnectIfAllowed(this, "task removed")
        super.onTaskRemoved(rootIntent)
        stopSelf()
    }
}
