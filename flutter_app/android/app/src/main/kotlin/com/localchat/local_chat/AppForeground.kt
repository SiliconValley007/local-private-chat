package com.localchat.local_chat

import android.app.ActivityManager
import android.content.Context
import android.os.Process

/**
 * Is a Local Chat window on screen right now, and if not, since when?
 *
 * [resumed] answers instantly for the common case; the process importance is
 * the fallback for a process the system just restarted for an alarm, where the
 * flag is back to its default.
 */
object AppForeground {
    @Volatile
    var resumed: Boolean = false
        private set

    /**
     * When the last window went away, as elapsed real time. Zero while a window
     * is up, and zero in a process that was started for a broadcast and has
     * never shown anything.
     */
    @Volatile
    var leftForegroundAtMs: Long = 0L
        private set

    /**
     * True while a call owns audio mode — the tunnel must stay up even with
     * the screen off.
     */
    @Volatile
    var callActive: Boolean = false
        private set

    @Volatile
    private var callActiveSinceMs: Long = 0L

    /**
     * True while a large upload (or similar transfer) is in flight.
     *
     * Switching apps mid-send used to drop Tailscale after the background
     * delay and kill the transfer. Holding the tunnel for the same reason a
     * call does keeps a 500 MB video alive when the user glances elsewhere.
     */
    @Volatile
    var transferActive: Boolean = false
        private set

    @Volatile
    private var transferActiveSinceMs: Long = 0L

    fun markResumed() {
        resumed = true
        leftForegroundAtMs = 0L
    }

    fun markStopped(nowMs: Long = System.currentTimeMillis()) {
        resumed = false
        leftForegroundAtMs = nowMs
    }

    fun noteCall(active: Boolean, nowMs: Long = System.currentTimeMillis()) {
        callActive = active
        callActiveSinceMs = if (active) nowMs else 0L
    }

    fun noteTransfer(active: Boolean, nowMs: Long = System.currentTimeMillis()) {
        transferActive = active
        transferActiveSinceMs = if (active) nowMs else 0L
    }

    /**
     * How long the app has been without a window, in milliseconds.
     *
     * Zero while a window is up. Also zero when this process never had one:
     * a process the system restarted for an alarm knows nothing about when the
     * user last looked at the app, and guessing "forever ago" there would let a
     * cold broadcast close a tunnel the running app still wants.
     */
    fun backgroundedForMs(nowMs: Long = System.currentTimeMillis()): Long {
        if (resumed || leftForegroundAtMs <= 0L) return 0L
        return (nowMs - leftForegroundAtMs).coerceAtLeast(0L)
    }

    /** The call flag, ignored once it is too old to be a real call. */
    fun callStillActive(nowMs: Long = System.currentTimeMillis()): Boolean =
        TailscaleExitPolicy.isCallStillActive(callActive, nowMs, callActiveSinceMs)

    /** The transfer flag, ignored once it is too old to be a real upload. */
    fun transferStillActive(nowMs: Long = System.currentTimeMillis()): Boolean =
        TailscaleExitPolicy.isTransferStillActive(
            transferActive,
            nowMs,
            transferActiveSinceMs,
        )

    /** Either kind of work that needs the tunnel while no window is showing. */
    fun keepTunnelAlive(nowMs: Long = System.currentTimeMillis()): Boolean =
        callStillActive(nowMs) || transferStillActive(nowMs)

    fun isForeground(context: Context): Boolean {
        if (resumed) return true
        val manager = context.applicationContext
            .getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return false
        val myPid = Process.myPid()
        val running = try {
            manager.runningAppProcesses
        } catch (_: Exception) {
            null
        } ?: return false
        return running.any {
            it.pid == myPid &&
                it.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
        }
    }
}
