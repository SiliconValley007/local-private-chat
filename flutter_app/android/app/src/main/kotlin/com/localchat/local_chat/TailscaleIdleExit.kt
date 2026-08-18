package com.localchat.local_chat

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Backstop disconnect for a process killed before [TailscaleGuardService] got
 * to it.
 *
 * The guard, task removal and `MainActivity.onDestroy` all need this process to
 * still exist. An alarm does not: the manifest receiver restarts the process to
 * run it. Phones that trim background apps hardest also tend to drop alarms for
 * apps they killed, which is why this is the backstop and not the plan.
 */
object TailscaleIdleExit {
    private const val TAG = "TailscaleIdleExit"
    const val ACTION = "com.localchat.local_chat.IDLE_TAILSCALE_EXIT"
    private const val REQUEST_CODE = 8471

    /** Called when the app leaves the foreground. */
    fun arm(context: Context) {
        val app = context.applicationContext
        val snap = TailscaleExit.readOwnership(app)
        if (!TailscaleExitPolicy.shouldArmIdleExit(snap.enabled, snap.phase)) {
            cancel(app)
            return
        }
        val alarms = alarmManager(app) ?: return
        val at = System.currentTimeMillis() + TailscaleExitPolicy.IDLE_EXIT_DELAY_MS
        try {
            // Inexact on purpose: exact alarms need a user-granted permission,
            // and a late disconnect is still a disconnect.
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending(app))
            Log.i(TAG, "idle exit armed in ${TailscaleExitPolicy.IDLE_EXIT_DELAY_MS} ms")
        } catch (e: Exception) {
            Log.w(TAG, "could not arm idle exit: ${e.message}")
        }
    }

    /** Called when the app comes back, or once the tunnel is already down. */
    fun cancel(context: Context) {
        val app = context.applicationContext
        try {
            alarmManager(app)?.cancel(pending(app))
        } catch (e: Exception) {
            Log.w(TAG, "could not cancel idle exit: ${e.message}")
        }
    }

    /**
     * Runs on the alarm; sets the timer again instead when the user is back in
     * the app or a call is still running, so a busy phone is checked later
     * rather than left connected for good.
     */
    fun onAlarm(context: Context, appForeground: Boolean, callActive: Boolean) {
        val app = context.applicationContext
        val snap = TailscaleExit.readOwnership(app)
        if (!TailscaleExitPolicy.shouldDisconnectOnIdleAlarm(
                snap.enabled,
                snap.phase,
                appForeground,
                callActive,
            )
        ) {
            if (appForeground || callActive) arm(app)
            return
        }
        TailscaleExit.disconnectIfAllowed(app, "idle in background")
    }

    private fun alarmManager(context: Context): AlarmManager? =
        context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager

    private fun pending(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        REQUEST_CODE,
        Intent(context, TailscaleIdleExitReceiver::class.java).setAction(ACTION),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
}
