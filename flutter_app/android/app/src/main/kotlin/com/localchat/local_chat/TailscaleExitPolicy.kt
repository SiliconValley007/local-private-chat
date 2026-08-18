package com.localchat.local_chat

/**
 * Pure exit/ownership policy — no Android APIs, safe for JVM unit tests.
 */
object TailscaleExitPolicy {
    const val CLAIM_WINDOW_MS = 30_000L

    /** Minimum gap between native DISCONNECT_VPN broadcasts (exit hooks can stack). */
    const val DISCONNECT_DEBOUNCE_MS = 2_500L

    /** Block CONNECT_VPN briefly after an exit disconnect so connect cannot race exit. */
    const val EXIT_CONNECT_GUARD_MS = 3_000L

    /** Cooldown for the compatibility retry exposed over the platform channel. */
    const val DISCONNECT_RETRY_COOLDOWN_MS = 30_000L

    /**
     * How long Local Chat may sit in the background before the tunnel it
     * switched on is dropped.
     *
     * Deliberately short, and deliberately acted on by code that is still
     * running: the app drops its socket the moment it leaves the foreground and
     * push wake-ups travel over ordinary internet, so a backgrounded Local Chat
     * has no use for the tunnel at all. Waiting instead for the app to be closed
     * is what left the tunnel on — by then the process is usually gone.
     *
     * Long enough that glancing at another app and coming back does not cost a
     * reconnect.
     */
    const val BACKGROUND_EXIT_DELAY_MS = 30_000L

    /** How often the guard looks at how long the app has been away. */
    const val GUARD_TICK_MS = 10_000L

    /**
     * Process-death-safe deadline. The in-process guard normally acts first at
     * 30 seconds; this alarm follows shortly afterwards if Android killed or
     * froze that process. Keeping this close to the guard closes the old
     * minutes-long hole where a later Recents swipe had no process to notify.
     */
    const val IDLE_EXIT_DELAY_MS = 45_000L

    /**
     * A call flag left standing by a crash must not keep the tunnel up forever.
     * No real call outlives this.
     */
    const val CALL_ACTIVE_MAX_MS = 6 * 60 * 60_000L

    /**
     * Same idea for a stuck upload flag: a multi-gigabyte send can take a while,
     * but nothing should pin the tunnel open overnight after a crash.
     */
    const val TRANSFER_ACTIVE_MAX_MS = 6 * 60 * 60_000L

    /**
     * May we switch the tunnel off?
     *
     * Any phase other than [TailscaleOwnershipPhase.UNOWNED] is ours to close.
     * [TailscaleOwnershipPhase.PENDING_CONNECT] is only ever written after
     * [mayPersistConnectIntent] found routing down, so it means "we asked
     * Tailscale to come up and never heard back" — which is a tunnel this app
     * started, whether or not the confirmation arrived. Treating it as someone
     * else's is what left tunnels on when the claim window closed unnoticed.
     */
    fun shouldDisconnectOnExit(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
    ): Boolean = enabled && phase != TailscaleOwnershipPhase.UNOWNED

    /** A task swipe must not cut the transport from underneath a live call or upload. */
    fun shouldDisconnectOnTaskRemoval(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
        callActive: Boolean,
        transferActive: Boolean = false,
    ): Boolean = !callActive && !transferActive && shouldDisconnectOnExit(enabled, phase)

    /**
     * The guard's periodic check: has the app been away long enough to close the
     * tunnel behind it?
     */
    fun shouldDisconnectAfterBackground(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
        appForeground: Boolean,
        callActive: Boolean,
        backgroundedForMs: Long,
        delayMs: Long = BACKGROUND_EXIT_DELAY_MS,
        transferActive: Boolean = false,
    ): Boolean {
        if (appForeground || callActive || transferActive) return false
        if (backgroundedForMs < delayMs) return false
        return shouldDisconnectOnExit(enabled, phase)
    }

    /** Is the call flag young enough to still believe? */
    fun isCallStillActive(
        callActive: Boolean,
        nowMs: Long,
        startedAtMs: Long,
        capMs: Long = CALL_ACTIVE_MAX_MS,
    ): Boolean {
        if (!callActive) return false
        if (startedAtMs <= 0L) return true
        return nowMs - startedAtMs < capMs
    }

    /** Is the transfer flag young enough to still believe? */
    fun isTransferStillActive(
        transferActive: Boolean,
        nowMs: Long,
        startedAtMs: Long,
        capMs: Long = TRANSFER_ACTIVE_MAX_MS,
    ): Boolean {
        if (!transferActive) return false
        if (startedAtMs <= 0L) return true
        return nowMs - startedAtMs < capMs
    }

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

    /** True when a disconnect was sent too recently to send another. */
    fun shouldDebounceDisconnect(
        nowMs: Long,
        lastDisconnectAtMs: Long,
        debounceMs: Long = DISCONNECT_DEBOUNCE_MS,
    ): Boolean =
        lastDisconnectAtMs > 0L && nowMs - lastDisconnectAtMs < debounceMs

    /** True when CONNECT_VPN must wait because an exit disconnect just fired. */
    fun shouldBlockConnectDuringExit(
        nowMs: Long,
        lastDisconnectAtMs: Long,
        guardMs: Long = EXIT_CONNECT_GUARD_MS,
    ): Boolean =
        lastDisconnectAtMs > 0L && nowMs - lastDisconnectAtMs < guardMs

    /**
     * Worth setting the background timer? Any tunnel we might own qualifies —
     * the phase is re-read when the timer fires, so arming costs nothing.
     */
    fun shouldArmIdleExit(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
    ): Boolean = enabled && phase != TailscaleOwnershipPhase.UNOWNED

    /**
     * The background timer fired: disconnect only if the user has not come back
     * and nothing is still using the tunnel.
     *
     * A voice call with the screen off looks exactly like an abandoned app from
     * the outside, and cutting its tunnel would drop the call.
     */
    fun shouldDisconnectOnIdleAlarm(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
        appForeground: Boolean,
        callActive: Boolean = false,
    ): Boolean {
        if (appForeground || callActive) return false
        return shouldDisconnectOnExit(enabled, phase)
    }

    /** Skip a duplicate compatibility retry. */
    fun shouldSkipDuplicateRetry(
        nowMs: Long,
        lastRetryAtMs: Long,
        cooldownMs: Long = DISCONNECT_RETRY_COOLDOWN_MS,
    ): Boolean =
        lastRetryAtMs > 0L && nowMs - lastRetryAtMs < cooldownMs

    private fun phaseRank(phase: TailscaleOwnershipPhase): Int = when (phase) {
        TailscaleOwnershipPhase.OWNED -> 3
        TailscaleOwnershipPhase.PENDING_CONNECT -> 2
        TailscaleOwnershipPhase.UNOWNED -> 1
    }

    /**
     * Stale Dart phase syncs must not downgrade [OWNED] or clobber a fresher phase.
     * [UNOWNED] always wins (explicit release).
     */
    fun mayApplyPhaseWrite(
        current: TailscaleOwnershipPhase,
        incoming: TailscaleOwnershipPhase,
    ): Boolean {
        if (incoming == TailscaleOwnershipPhase.UNOWNED) return true
        return phaseRank(incoming) >= phaseRank(current)
    }
}
