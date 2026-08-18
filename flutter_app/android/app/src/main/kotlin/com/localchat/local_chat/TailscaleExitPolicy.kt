package com.localchat.local_chat

/**
 * Pure exit/ownership policy — no Android APIs, safe for JVM unit tests.
 */
object TailscaleExitPolicy {
    const val CLAIM_WINDOW_MS = 30_000L

    fun shouldDisconnectOnExit(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
    ): Boolean = enabled && phase == TailscaleOwnershipPhase.OWNED

    /** Legacy boolean mirror used by older Dart builds. */
    fun startedByApp(phase: TailscaleOwnershipPhase): Boolean =
        phase == TailscaleOwnershipPhase.OWNED

    /**
     * May we persist [TailscaleOwnershipPhase.PENDING_CONNECT] before CONNECT_VPN?
     *
     * Routing must have been down and the tunnel must not already be carrying
     * traffic — otherwise we would adopt someone else's tunnel.
     */
    fun mayPersistConnectIntent(routingWasDown: Boolean, routingAlreadyUp: Boolean): Boolean =
        routingWasDown && !routingAlreadyUp

    /**
     * After a connectivity observation while [PENDING_CONNECT], may we claim [OWNED]?
     */
    fun mayClaimOwned(
        phase: TailscaleOwnershipPhase,
        routingUp: Boolean,
        routingRoseAfterRequest: Boolean,
        connectRequestedAtMs: Long,
        nowMs: Long,
    ): Boolean {
        if (phase != TailscaleOwnershipPhase.PENDING_CONNECT) return false
        if (!routingUp || !routingRoseAfterRequest) return false
        if (connectRequestedAtMs <= 0L) return false
        return nowMs - connectRequestedAtMs <= CLAIM_WINDOW_MS
    }

    /**
     * A [PENDING_CONNECT] that outlived the claim window with routing up belongs
     * to someone else.
     */
    fun pendingConnectExpired(
        phase: TailscaleOwnershipPhase,
        routingUp: Boolean,
        connectRequestedAtMs: Long,
        nowMs: Long,
    ): Boolean {
        if (phase != TailscaleOwnershipPhase.PENDING_CONNECT) return false
        if (!routingUp) return false
        if (connectRequestedAtMs <= 0L) return true
        return nowMs - connectRequestedAtMs > CLAIM_WINDOW_MS
    }

    /**
     * Release [OWNED] once the tunnel is provably gone (disconnect succeeded).
     */
    fun shouldReleaseOwned(
        phase: TailscaleOwnershipPhase,
        tunnelProvablyDown: Boolean,
    ): Boolean = phase == TailscaleOwnershipPhase.OWNED && tunnelProvablyDown

    /**
     * On cold start, retry disconnect when a previous run owned the tunnel but
     * the process died before DISCONNECT_VPN finished.
     */
    fun shouldRetryInterruptedDisconnect(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
    ): Boolean = enabled && phase == TailscaleOwnershipPhase.OWNED
}
