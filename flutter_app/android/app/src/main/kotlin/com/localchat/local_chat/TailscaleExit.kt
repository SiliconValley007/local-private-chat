package com.localchat.local_chat

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Durable Tailscale ownership and exit disconnect.
 *
 * Kotlin owns the state machine because swiping the app away tears the Dart
 * isolate down before async work finishes. Native prefs survive process loss
 * until disconnect succeeds or the tunnel is provably down.
 */
object TailscaleExit {
    const val CHANNEL = "local_chat/tailscale"
    private const val TAG = "TailscaleExit"

    private const val PREFS = "localchat_tailscale_exit"
    private const val KEY_ENABLED = "enabled"
    private const val KEY_PHASE = "ownership_phase_v2"
    private const val KEY_CONNECT_AT = "connect_requested_at_ms"
    /** Legacy mirror; [KEY_PHASE] is authoritative. */
    private const val KEY_STARTED_BY_APP = "started_by_app"
    private const val KEY_LAST_DISCONNECT_AT = "last_disconnect_at_ms"
    private const val KEY_DISCONNECT_RETRY_AT = "disconnect_retry_at_ms"
    private const val KEY_ACTIVITY_STOPPED_AT = "activity_stopped_at_ms"
    private const val KEY_PENDING_DISCONNECT = "pending_disconnect"
    private const val KEY_EVENT_LOG = "tunnel_event_log"

    /** Enough history to explain one session without growing without bound. */
    private const val EVENT_LOG_LIMIT = 24

    /** In-process mirror of [KEY_LAST_DISCONNECT_AT] for connect/exit guards. */
    @Volatile
    private var lastDisconnectAtMs: Long = 0L

    private const val TAILSCALE_PACKAGE = "com.tailscale.ipn"
    private const val TAILSCALE_RECEIVER = "com.tailscale.ipn.IPNReceiver"
    private const val CONNECT_ACTION = "com.tailscale.ipn.CONNECT_VPN"
    private const val DISCONNECT_ACTION = "com.tailscale.ipn.DISCONNECT_VPN"

    data class OwnershipSnapshot(
        val phase: TailscaleOwnershipPhase,
        val connectRequestedAtMs: Long,
        val enabled: Boolean,
    )

    private fun prefs(context: Context) = context.applicationContext
        .getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun readPhaseRaw(context: Context): TailscaleOwnershipPhase {
        val stored = prefs(context).getString(KEY_PHASE, null)
        if (stored != null) return TailscaleOwnershipPhase.fromWire(stored)
        // Migrate legacy boolean-only installs.
        return if (prefs(context).getBoolean(KEY_STARTED_BY_APP, false)) {
            TailscaleOwnershipPhase.OWNED
        } else {
            TailscaleOwnershipPhase.UNOWNED
        }
    }

    fun readOwnership(context: Context): OwnershipSnapshot {
        val p = prefs(context)
        return OwnershipSnapshot(
            phase = readPhaseRaw(context),
            connectRequestedAtMs = p.getLong(KEY_CONNECT_AT, 0L),
            enabled = p.getBoolean(KEY_ENABLED, false),
        )
    }

    fun readPolicy(context: Context): Map<String, Any?> {
        val snap = readOwnership(context)
        return mapOf(
            "enabled" to snap.enabled,
            "startedByApp" to TailscaleExitPolicy.startedByApp(snap.phase),
            "phase" to snap.phase.wire,
            "connectRequestedAtMs" to snap.connectRequestedAtMs,
            "activityStoppedAtMs" to activityStoppedAt(context),
            "pendingDisconnect" to isPendingDisconnect(context),
        )
    }

    fun isPendingDisconnect(context: Context): Boolean =
        prefs(context).getBoolean(KEY_PENDING_DISCONNECT, false)

    fun notePendingDisconnect(context: Context) {
        val snap = readOwnership(context)
        if (!TailscaleExitPolicy.shouldNotePendingDisconnect(snap.enabled, snap.phase)) {
            return
        }
        prefs(context.applicationContext).edit()
            .putBoolean(KEY_PENDING_DISCONNECT, true)
            .apply()
    }

    fun clearPendingDisconnect(context: Context) {
        prefs(context.applicationContext).edit()
            .putBoolean(KEY_PENDING_DISCONNECT, false)
            .apply()
    }

    /**
     * Records what was asked of Tailscale and why, for the settings screen.
     *
     * Whether a tunnel was switched off on the way out is otherwise invisible
     * without a USB cable and `logcat`, which left "it did not disconnect" and
     * "it disconnected a second after you stopped recording" indistinguishable.
     */
    fun note(context: Context, text: String, nowMs: Long = System.currentTimeMillis()) {
        val app = context.applicationContext
        val existing = prefs(app).getString(KEY_EVENT_LOG, "").orEmpty()
        val kept = existing.split('\n')
            .filter { it.isNotBlank() }
            .takeLast(EVENT_LOG_LIMIT - 1)
        val line = "$nowMs|${text.replace('\n', ' ').replace('|', '/')}"
        prefs(app).edit()
            .putString(KEY_EVENT_LOG, (kept + line).joinToString("\n"))
            .apply()
    }

    /** Newest last, as `[{atMs, text}]` for the Dart side. */
    fun readEventLog(context: Context): List<Map<String, Any?>> {
        val raw = prefs(context.applicationContext).getString(KEY_EVENT_LOG, "").orEmpty()
        return raw.split('\n').mapNotNull { entry ->
            if (entry.isBlank()) return@mapNotNull null
            val at = entry.substringBefore('|').toLongOrNull() ?: return@mapNotNull null
            mapOf("atMs" to at, "text" to entry.substringAfter('|'))
        }
    }

    /** Durable wall-clock time when Local Chat's last activity left the screen. */
    fun noteActivityStopped(context: Context, nowMs: Long = System.currentTimeMillis()) {
        prefs(context).edit().putLong(KEY_ACTIVITY_STOPPED_AT, nowMs).apply()
    }

    /** A visible activity cancels every process-death interpretation of "away". */
    fun noteActivityResumed(context: Context) {
        prefs(context).edit()
            .putLong(KEY_ACTIVITY_STOPPED_AT, 0L)
            .putLong(KEY_LAST_DISCONNECT_AT, 0L)
            .apply()
        lastDisconnectAtMs = 0L
        clearPendingDisconnect(context)
    }

    fun activityStoppedAt(context: Context): Long =
        prefs(context).getLong(KEY_ACTIVITY_STOPPED_AT, 0L)

    fun durableBackgroundedForMs(
        context: Context,
        nowMs: Long = System.currentTimeMillis(),
    ): Long {
        val stoppedAt = activityStoppedAt(context)
        if (stoppedAt <= 0L) return 0L
        return (nowMs - stoppedAt).coerceAtLeast(0L)
    }

    fun savePolicy(context: Context, enabled: Boolean, phase: TailscaleOwnershipPhase) {
        val app = context.applicationContext
        val current = readPhaseRaw(app)
        if (!TailscaleExitPolicy.mayApplyPolicyPhaseWrite(current, phase)) {
            Log.i(
                TAG,
                "policy phase ignored (current=${current.wire} incoming=${phase.wire})",
            )
            prefs(app).edit().putBoolean(KEY_ENABLED, enabled).apply()
            return
        }
        prefs(app).edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putString(KEY_PHASE, phase.wire)
            .putBoolean(
                KEY_STARTED_BY_APP,
                TailscaleExitPolicy.startedByApp(phase),
            )
            .apply()
        Log.i(TAG, "policy saved: enabled=$enabled phase=${phase.wire}")
    }

    /** Dart-side phase sync without touching [KEY_CONNECT_AT]. */
    fun savePhase(context: Context, phase: TailscaleOwnershipPhase) {
        val app = context.applicationContext
        val current = readPhaseRaw(app)
        if (!TailscaleExitPolicy.mayApplyPhaseWrite(current, phase)) {
            Log.i(
                TAG,
                "phase write ignored (current=${current.wire} incoming=${phase.wire})",
            )
            return
        }
        prefs(app).edit()
            .putString(KEY_PHASE, phase.wire)
            .putBoolean(
                KEY_STARTED_BY_APP,
                TailscaleExitPolicy.startedByApp(phase),
            )
            .apply()
        Log.i(TAG, "phase saved: ${phase.wire}")
    }

    /**
     * Atomically records connect intent, then broadcasts CONNECT_VPN.
     *
     * When [routingWasDown] is false the broadcast still goes out (nudge) but
     * ownership stays unowned so a pre-routed tunnel is never adopted.
     */
    fun requestConnect(
        context: Context,
        routingWasDown: Boolean,
        routingAlreadyUp: Boolean,
    ): Boolean {
        val app = context.applicationContext
        val now = System.currentTimeMillis()
        val lastDisconnect = lastDisconnectAt(app, now)
        if (TailscaleExitPolicy.shouldBlockConnectDuringExit(now, lastDisconnect)) {
            Log.i(TAG, "connect blocked: exit disconnect guard active")
            note(app, "Connect held back: a disconnect had just been sent", now)
            return false
        }
        if (TailscaleExitPolicy.mayPersistConnectIntent(routingWasDown, routingAlreadyUp)) {
            val current = readPhaseRaw(app)
            if (TailscaleExitPolicy.mayApplyPhaseWrite(
                    current,
                    TailscaleOwnershipPhase.PENDING_CONNECT,
                )
            ) {
                prefs(app).edit()
                    .putString(KEY_PHASE, TailscaleOwnershipPhase.PENDING_CONNECT.wire)
                    .putLong(KEY_CONNECT_AT, now)
                    .putBoolean(KEY_STARTED_BY_APP, false)
                    .apply()
                Log.i(TAG, "connect intent persisted at $now")
                note(app, "Asked Tailscale to connect, and claimed the tunnel", now)
            } else {
                Log.i(TAG, "connect intent skipped: phase write rejected")
            }
        } else {
            Log.i(
                TAG,
                "connect nudge without claim (routingWasDown=$routingWasDown " +
                    "routingAlreadyUp=$routingAlreadyUp)",
            )
            note(
                app,
                "Asked Tailscale to connect without claiming: the tunnel was " +
                    "already carrying traffic",
                now,
            )
        }
        return sendConnectBroadcast(app)
    }

    fun markOwned(context: Context) {
        savePhase(context, TailscaleOwnershipPhase.OWNED)
        Log.i(TAG, "ownership claimed")
        note(context, "Tunnel confirmed as this app's to close")
    }

    fun releaseOwnership(context: Context, reason: String) {
        prefs(context.applicationContext).edit()
            .putString(KEY_PHASE, TailscaleOwnershipPhase.UNOWNED.wire)
            .putLong(KEY_CONNECT_AT, 0L)
            .putBoolean(KEY_STARTED_BY_APP, false)
            .putBoolean(KEY_PENDING_DISCONNECT, false)
            .apply()
        Log.i(TAG, "ownership released: $reason")
        note(context, "Stopped treating the tunnel as ours ($reason)")
    }

    /** Records every reason the primary exit hook deliberately kept a tunnel. */
    fun noteExitSkipped(
        context: Context,
        reason: String,
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
        changingConfigurations: Boolean,
        callActive: Boolean,
        transferActive: Boolean,
        expectingReturn: Boolean,
    ) {
        val causes = buildList {
            if (!enabled) add("exit setting off")
            if (phase == TailscaleOwnershipPhase.UNOWNED) add("tunnel not ours")
            if (changingConfigurations) add("configuration change")
            if (callActive) add("call active")
            if (transferActive) add("upload active")
            if (expectingReturn) add("expected return")
        }
        note(
            context,
            "$reason: kept tunnel (${causes.joinToString().ifEmpty { "unknown policy reason" }})",
        )
    }

    /** Sends DISCONNECT_VPN only when the saved rule allows it. Keeps [OWNED]. */
    fun disconnectIfAllowed(
        context: Context,
        reason: String,
        authoritative: Boolean = false,
    ) {
        val snap = readOwnership(context)
        if (!TailscaleExitPolicy.shouldDisconnectOnExit(snap.enabled, snap.phase)) {
            Log.i(
                TAG,
                "$reason: leaving tunnel up (enabled=${snap.enabled} phase=${snap.phase.wire})",
            )
            note(
                context,
                if (snap.enabled) {
                    "$reason: left the tunnel alone, it is not ours"
                } else {
                    "$reason: left the tunnel alone, switching off on exit is off"
                },
            )
            return
        }
        notePendingDisconnect(context)
        sendDisconnectBroadcast(context.applicationContext, reason, authoritative)
    }

    /** Sends DISCONNECT_VPN regardless of rule (manual action). Clears ownership. */
    fun disconnectNow(context: Context, reason: String) {
        releaseOwnership(context, reason)
        sendDisconnectBroadcast(context.applicationContext, reason)
    }

    /** How long the app has been away according to durable prefs. */
    fun backgroundedForMs(
        context: Context,
        nowMs: Long = System.currentTimeMillis(),
    ): Long = durableBackgroundedForMs(context, nowMs)

    /**
     * Retry a pending exit disconnect when the short ladder or backstop fires.
     */
    fun retryPendingDisconnectIfNeeded(
        context: Context,
        authoritative: Boolean = false,
    ) {
        val app = context.applicationContext
        val snap = readOwnership(app)
        val now = System.currentTimeMillis()
        val backgroundedForMs = durableBackgroundedForMs(app, now)
        if (!TailscaleExitPolicy.shouldRetryPendingDisconnect(
                pendingDisconnect = isPendingDisconnect(app),
                enabled = snap.enabled,
                phase = snap.phase,
                backgroundedForMs = backgroundedForMs,
                callActive = AppForeground.callStillActive(now),
                transferActive = AppForeground.transferStillActive(now),
                expectingReturn = AppForeground.expectingReturn(now),
            )
        ) {
            return
        }
        sendDisconnectBroadcast(app, "pending disconnect retry", authoritative)
    }

    /**
     * Cold-start retry when the previous run owned the tunnel but died mid-disconnect.
     */
    fun retryInterruptedDisconnectIfNeeded(context: Context) {
        val app = context.applicationContext
        val snap = readOwnership(app)
        val now = System.currentTimeMillis()
        if (!TailscaleExitPolicy.shouldRetryInterruptedDisconnect(
                snap.enabled,
                snap.phase,
                durableBackgroundedForMs(app, now),
            )
        ) {
            return
        }
        val p = prefs(app)
        val lastRetry = p.getLong(KEY_DISCONNECT_RETRY_AT, 0L)
        if (TailscaleExitPolicy.shouldSkipDuplicateRetry(now, lastRetry)) {
            Log.i(TAG, "skipping duplicate interrupted disconnect retry")
            return
        }
        p.edit().putLong(KEY_DISCONNECT_RETRY_AT, now).apply()
        Log.i(TAG, "retrying interrupted owned disconnect")
        sendDisconnectBroadcast(app, "retry interrupted disconnect", authoritative = true)
    }

    private fun lastDisconnectAt(context: Context, now: Long): Long {
        if (lastDisconnectAtMs > 0L) return lastDisconnectAtMs
        val stored = prefs(context).getLong(KEY_LAST_DISCONNECT_AT, 0L)
        if (stored > 0L) lastDisconnectAtMs = stored
        return stored
    }

    private fun noteDisconnectSent(context: Context, now: Long) {
        lastDisconnectAtMs = now
        prefs(context.applicationContext).edit()
            .putLong(KEY_LAST_DISCONNECT_AT, now)
            .apply()
    }

    private fun sendConnectBroadcast(context: Context): Boolean {
        return try {
            val intent = Intent(CONNECT_ACTION).apply {
                component = ComponentName(TAILSCALE_PACKAGE, TAILSCALE_RECEIVER)
                setPackage(TAILSCALE_PACKAGE)
            }
            context.sendBroadcast(intent)
            Log.i(TAG, "sent CONNECT_VPN")
            true
        } catch (e: Exception) {
            Log.w(TAG, "could not connect Tailscale: ${e.message}")
            false
        }
    }

    private fun sendDisconnectBroadcast(
        context: Context,
        reason: String,
        authoritative: Boolean = false,
    ) {
        val now = System.currentTimeMillis()
        val last = lastDisconnectAt(context, now)
        if (TailscaleExitPolicy.shouldDebounceDisconnect(now, last, authoritative = authoritative)) {
            Log.i(TAG, "$reason: debounced duplicate DISCONNECT_VPN")
            return
        }
        noteDisconnectSent(context, now)
        try {
            val intent = Intent(DISCONNECT_ACTION).apply {
                component = ComponentName(TAILSCALE_PACKAGE, TAILSCALE_RECEIVER)
                setPackage(TAILSCALE_PACKAGE)
            }
            context.sendBroadcast(intent)
            Log.i(TAG, "$reason: sent DISCONNECT_VPN")
            note(context, "Asked Tailscale to disconnect ($reason)", now)
        } catch (e: Exception) {
            Log.w(TAG, "$reason: could not disconnect Tailscale: ${e.message}")
            note(context, "Could not reach Tailscale to disconnect ($reason)", now)
        }
    }
}
