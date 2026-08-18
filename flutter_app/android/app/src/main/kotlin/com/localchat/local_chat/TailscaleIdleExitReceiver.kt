package com.localchat.local_chat

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Wakes this process (restarting it if Android already reaped it) so the
 * background timer can switch the tunnel off.
 */
class TailscaleIdleExitReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != TailscaleIdleExit.ACTION) return
        TailscaleIdleExit.onAlarm(
            context,
            AppForeground.isForeground(context),
            AppForeground.callStillActive(),
        )
    }
}
