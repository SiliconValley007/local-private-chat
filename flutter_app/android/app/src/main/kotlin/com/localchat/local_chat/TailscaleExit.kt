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
        )
    }

    fun savePolicy(context: Context, enabled: Boolean, phase: TailscaleOwnershipPhase) {
        prefs(context).edit()
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
        prefs(context).edit()
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
        if (TailscaleExitPolicy.mayPersistConnectIntent(routingWasDown, routingAlreadyUp)) {
            val now = System.currentTimeMillis()
            prefs(app).edit()
                .putString(KEY_PHASE, TailscaleOwnershipPhase.PENDING_CONNECT.wire)
                .putLong(KEY_CONNECT_AT, now)
                .putBoolean(KEY_STARTED_BY_APP, false)
                .apply()
            Log.i(TAG, "connect intent persisted at $now")
        } else {
            Log.i(
                TAG,
                "connect nudge without claim (routingWasDown=$routingWasDown " +
                    "routingAlreadyUp=$routingAlreadyUp)",
            )
        }
        return sendConnectBroadcast(app)
    }

    fun markOwned(context: Context) {
        savePhase(context, TailscaleOwnershipPhase.OWNED)
        Log.i(TAG, "ownership claimed")
    }

    fun releaseOwnership(context: Context, reason: String) {
        prefs(context.applicationContext).edit()
            .putString(KEY_PHASE, TailscaleOwnershipPhase.UNOWNED.wire)
            .putLong(KEY_CONNECT_AT, 0L)
            .putBoolean(KEY_STARTED_BY_APP, false)
            .apply()
        Log.i(TAG, "ownership released: $reason")
    }

    /** Sends DISCONNECT_VPN only when the saved rule allows it. Keeps [OWNED]. */
    fun disconnectIfAllowed(context: Context, reason: String) {
        val snap = readOwnership(context)
        if (!TailscaleExitPolicy.shouldDisconnectOnExit(snap.enabled, snap.phase)) {
            Log.i(
                TAG,
                "$reason: leaving tunnel up (enabled=${snap.enabled} phase=${snap.phase.wire})",
            )
            return
        }
        sendDisconnectBroadcast(context.applicationContext, reason)
    }

    /** Sends DISCONNECT_VPN regardless of rule (manual action). Clears ownership. */
    fun disconnectNow(context: Context, reason: String) {
        releaseOwnership(context, reason)
        sendDisconnectBroadcast(context.applicationContext, reason)
    }

    /**
     * Cold-start retry when the previous run owned the tunnel but died mid-disconnect.
     */
    fun retryInterruptedDisconnectIfNeeded(context: Context) {
        val snap = readOwnership(context)
        if (!TailscaleExitPolicy.shouldRetryInterruptedDisconnect(snap.enabled, snap.phase)) {
            return
        }
        Log.i(TAG, "retrying interrupted owned disconnect")
        sendDisconnectBroadcast(context.applicationContext, "retry interrupted disconnect")
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

    private fun sendDisconnectBroadcast(context: Context, reason: String) {
        try {
            val intent = Intent(DISCONNECT_ACTION).apply {
                component = ComponentName(TAILSCALE_PACKAGE, TAILSCALE_RECEIVER)
                setPackage(TAILSCALE_PACKAGE)
            }
            context.sendBroadcast(intent)
            Log.i(TAG, "$reason: sent DISCONNECT_VPN")
        } catch (e: Exception) {
            Log.w(TAG, "$reason: could not disconnect Tailscale: ${e.message}")
        }
    }
}
