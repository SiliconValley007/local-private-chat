package com.localchat.local_chat

import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log

/**
 * Closes the Tailscale tunnel Local Chat opened, from inside the running app.
 *
 * Earlier builds waited for the app to be *closed* and then acted — on task
 * removal, on activity finish, or on an alarm meant to restart a dead process.
 * All three depend on Android, or the phone's vendor, letting us run after the
 * app is out of sight, and on a phone that trims background apps hard they
 * simply never arrive: minimise Local Chat, leave it half an hour, swipe it
 * away, and the tunnel stayed on because nobody was left to switch it off.
 *
 * So the decision is taken while the app is unquestionably alive. A short while
 * after the last window goes away — [TailscaleExitPolicy.BACKGROUND_EXIT_DELAY_MS]
 * — the tunnel is dropped, because a backgrounded Local Chat has no use for it:
 * the socket is already released on background and push wake-ups arrive over
 * ordinary internet. By the time the user gets around to swiping the app away,
 * there is nothing left to disconnect.
 *
 * The state it reads ([AppForeground]) is shared memory in the same process, so
 * nothing has to start a service or send a broadcast from the background — the
 * two things a vendor's battery saver blocks first.
 */
class TailscaleGuardService : Service() {
    private val handler = Handler(Looper.getMainLooper())

    /** Set while a tunnel of ours may still be up, so [onDestroy] can act. */
    private var watching = false

    private val tick = object : Runnable {
        override fun run() {
            if (!watching) return
            if (closeTunnelIfAppIsGone("left in the background")) return
            handler.postDelayed(this, TailscaleExitPolicy.GUARD_TICK_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        watching = true
        handler.postDelayed(tick, TailscaleExitPolicy.GUARD_TICK_MS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Restarted by the system, or told to look again by the activity: either
        // way the countdown is driven off AppForeground, so there is nothing to
        // read out of the intent.
        if (!watching) {
            watching = true
            handler.postDelayed(tick, TailscaleExitPolicy.GUARD_TICK_MS)
        }
        // A restart has lost AppForeground.leftForegroundAtMs, so it cannot
        // reconstruct the countdown safely. The AlarmManager deadline survives
        // process death and is the component that should take over.
        return START_NOT_STICKY
    }

    /**
     * Android's one reliable signal that the app was swiped out of Recents,
     * for the case the user gets there before the countdown does.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        val snap = TailscaleExit.readOwnership(this)
        val keepAlive = AppForeground.keepTunnelAlive()
        val disconnect = TailscaleExitPolicy.shouldDisconnectOnTaskRemoval(
            enabled = snap.enabled,
            phase = snap.phase,
            callActive = AppForeground.callStillActive(),
            transferActive = AppForeground.transferStillActive(),
        )
        if (keepAlive) {
            // A live call or upload still needs the tunnel; arm the idle alarm
            // as a backstop if the process dies before the work finishes.
            Log.i(TAG, "task removed while keep-alive work is active; tunnel held")
            TailscaleIdleExit.arm(this)
        } else if (disconnect) {
            TailscaleExit.disconnectIfAllowed(this, "task removed")
            // Keep the already-armed alarm: it sends one later fallback nudge
            // if Tailscale ignored this best-effort broadcast.
        }
        super.onTaskRemoved(rootIntent)
        if (!keepAlive) stopSelf()
    }

    /**
     * The system is taking the guard down — background services are stopped a
     * minute or so after an app leaves the foreground. If the app is away and a
     * tunnel of ours is still up, this is the last moment we will be asked, so
     * the tunnel goes now rather than never.
     */
    override fun onDestroy() {
        handler.removeCallbacks(tick)
        // No delay to satisfy here: this is the last time this process will be
        // asked anything, so any wait still to run is served now.
        if (watching) {
            closeTunnelIfAppIsGone("guard stopping while app is away", delayMs = 1L)
        }
        watching = false
        super.onDestroy()
    }

    /** Returns true when the tunnel was closed and the guard is done. */
    private fun closeTunnelIfAppIsGone(
        reason: String,
        delayMs: Long = TailscaleExitPolicy.BACKGROUND_EXIT_DELAY_MS,
    ): Boolean {
        val snap = TailscaleExit.readOwnership(this)
        val now = System.currentTimeMillis()
        val disconnect = TailscaleExitPolicy.shouldDisconnectAfterBackground(
            enabled = snap.enabled,
            phase = snap.phase,
            appForeground = AppForeground.isForeground(this),
            callActive = AppForeground.callStillActive(now),
            backgroundedForMs = AppForeground.backgroundedForMs(now),
            delayMs = delayMs,
            transferActive = AppForeground.transferStillActive(now),
        )
        if (!disconnect) return false
        Log.i(TAG, "$reason: closing the tunnel this app opened")
        TailscaleExit.disconnectIfAllowed(this, reason)
        // Keep the alarm armed after this best-effort broadcast. Tailscale's
        // receiver sends no acknowledgement, so the later alarm doubles as one
        // process-death-safe delivery retry. Returning to the app cancels it.
        watching = false
        stopSelf()
        return true
    }

    companion object {
        private const val TAG = "TailscaleGuard"

        /**
         * Starts (or pokes) the guard. Called from a resumed activity, which is
         * the only state in which starting a service is unconditionally allowed.
         */
        fun watch(context: Context) {
            try {
                context.startService(Intent(context, TailscaleGuardService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "guard not started: ${e.message}")
            }
        }
    }
}
