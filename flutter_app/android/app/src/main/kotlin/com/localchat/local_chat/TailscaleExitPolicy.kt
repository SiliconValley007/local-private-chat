package com.localchat.local_chat

/**
 * Pure exit/ownership policy — no Android APIs, safe for JVM unit tests.
 */
object TailscaleExitPolicy {
    /**
     * How long a PENDING_CONNECT may wait before routing that appears is no
     * longer attributed to our request.
     *
     * Only a bound on attribution when nothing was observed rising — routing we
     * actually watched rise is ours at any age. Roaming and metered links can
     * take minutes to route, and the old half-minute limit handed those tunnels
     * back to "unowned", which is how a tunnel this app switched on outlived it.
     */
    const val CLAIM_WINDOW_MS = 180_000L

    /** Minimum gap between native DISCONNECT_VPN broadcasts (exit hooks can stack). */
    const val DISCONNECT_DEBOUNCE_MS = 2_500L

    /**
     * First retry after an exit disconnect that Tailscale may have ignored.
     *
     * The 45s alarm backstop still follows; this closes the gap when the user
     * minimises, waits a few seconds, and swipes the app away before the guard
     * or backstop would otherwise run.
     */
    const val PENDING_DISCONNECT_RETRY_MS = 5_000L

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
     * A "we opened something else, expect the user straight back" flag must not
     * hold the tunnel open indefinitely if the return never happens.
     */
    const val EXPECT_RETURN_MAX_MS = 2 * 60_000L

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

    /**
     * The app's last window is going away — switch the tunnel off now?
     *
     * This is the only exit decision taken by code Android guarantees to run:
     * `onStop` happens while the process is unquestionably alive. Everything
     * that waits — the guard's countdown, the alarm backstop — depends on a
     * cached process still being allowed to think, which the phones that trim
     * background apps hardest simply do not allow. Waiting half a minute was
     * therefore a promise this app could not keep, and the tunnel stayed up.
     *
     * A rotation is not leaving, live work keeps its transport, and
     * [expectingReturn] covers the app sending the user somewhere else on
     * purpose — Tailscale's own app, or the system's fingerprint sheet — where
     * dropping the tunnel would undo what they just asked for.
     */
    fun shouldDisconnectOnLeavingApp(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
        changingConfigurations: Boolean,
        keepTunnelAlive: Boolean,
        expectingReturn: Boolean,
    ): Boolean {
        if (changingConfigurations) return false
        if (keepTunnelAlive) return false
        if (expectingReturn) return false
        return shouldDisconnectOnExit(enabled, phase)
    }

    /** Is the expect-return flag young enough to still believe? */
    fun isExpectReturnStillActive(
        expectReturn: Boolean,
        nowMs: Long,
        startedAtMs: Long,
        capMs: Long = EXPECT_RETURN_MAX_MS,
    ): Boolean {
        if (!expectReturn) return false
        if (startedAtMs <= 0L) return true
        return nowMs - startedAtMs < capMs
    }

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
        expectingReturn: Boolean = false,
    ): Boolean {
        if (appForeground || callActive || transferActive || expectingReturn) return false
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
     *
     * Routing seen rising while pending is ours however long it took: the phase
     * was only written because routing was down when we asked. The window below
     * only bounds the ambiguous case where routing was already up the first time
     * this process looked.
     */
    fun mayClaimOwned(
        phase: TailscaleOwnershipPhase,
        routingUp: Boolean,
        routingRoseAfterRequest: Boolean,
        connectRequestedAtMs: Long,
        nowMs: Long,
    ): Boolean {
        if (phase != TailscaleOwnershipPhase.PENDING_CONNECT) return false
        if (!routingUp) return false
        if (connectRequestedAtMs <= 0L) return false
        if (routingRoseAfterRequest) return true
        return nowMs - connectRequestedAtMs <= CLAIM_WINDOW_MS
    }

    /**
     * A [PENDING_CONNECT] with routing up that we never watched rise, past the
     * claim window, belongs to someone else.
     */
    fun pendingConnectExpired(
        phase: TailscaleOwnershipPhase,
        routingUp: Boolean,
        connectRequestedAtMs: Long,
        nowMs: Long,
        routingRoseAfterRequest: Boolean = false,
    ): Boolean {
        if (phase != TailscaleOwnershipPhase.PENDING_CONNECT) return false
        if (!routingUp) return false
        if (routingRoseAfterRequest) return false
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
     * Retry a disconnect that a dying process never completed.
     *
     * Only for callers that run without the app being opened — a background
     * wake-up. Never wire this into activity startup: opening the app means the
     * user wants the tunnel, the DISCONNECT would race the CONNECT that follows
     * a moment later, and [shouldBlockConnectDuringExit] would then refuse that
     * CONNECT, leaving a running tunnel nobody claims.
     */
    fun shouldRetryInterruptedDisconnect(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
        backgroundedForMs: Long,
        delayMs: Long = IDLE_EXIT_DELAY_MS,
    ): Boolean =
        enabled &&
            phase == TailscaleOwnershipPhase.OWNED &&
            backgroundedForMs >= delayMs

    /** True when a disconnect was sent too recently to send another. */
    fun shouldDebounceDisconnect(
        nowMs: Long,
        lastDisconnectAtMs: Long,
        debounceMs: Long = DISCONNECT_DEBOUNCE_MS,
        authoritative: Boolean = false,
    ): Boolean {
        if (authoritative) return false
        return lastDisconnectAtMs > 0L && nowMs - lastDisconnectAtMs < debounceMs
    }

    /** May we record that an exit disconnect still needs confirmation? */
    fun shouldNotePendingDisconnect(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
    ): Boolean = shouldDisconnectOnExit(enabled, phase)

    /** A visible activity means any pending exit work is cancelled. */
    fun shouldClearPendingDisconnect(appForeground: Boolean): Boolean = appForeground

    /**
     * Retry a disconnect the first exit hook may have missed.
     *
     * Only after [PENDING_DISCONNECT_RETRY_MS] away, and only while a pending
     * flag says the first attempt has not been confirmed down.
     */
    fun shouldRetryPendingDisconnect(
        pendingDisconnect: Boolean,
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
        backgroundedForMs: Long,
        retryMs: Long = PENDING_DISCONNECT_RETRY_MS,
        callActive: Boolean = false,
        transferActive: Boolean = false,
        expectingReturn: Boolean = false,
    ): Boolean {
        if (!pendingDisconnect) return false
        if (callActive || transferActive || expectingReturn) return false
        if (backgroundedForMs < retryMs) return false
        return shouldDisconnectOnExit(enabled, phase)
    }

    /**
     * When to set the idle alarm next, measured from how long the app has
     * already been away.
     */
    fun idleExitArmDelayMs(
        backgroundedForMs: Long,
        shortRetryMs: Long = PENDING_DISCONNECT_RETRY_MS,
        backstopMs: Long = IDLE_EXIT_DELAY_MS,
    ): Long = when {
        backgroundedForMs <= 0L -> shortRetryMs
        backgroundedForMs < shortRetryMs -> shortRetryMs - backgroundedForMs
        backgroundedForMs < backstopMs -> backstopMs - backgroundedForMs
        else -> 1L
    }

    /**
     * The alarm fired but it is still too early, or a hold is active — set the
     * timer again rather than leaving the tunnel up for good.
     */
    fun shouldRearmIdleExitOnAlarm(
        backgroundedForMs: Long,
        delayMs: Long = IDLE_EXIT_DELAY_MS,
        callActive: Boolean = false,
        transferActive: Boolean = false,
        expectingReturn: Boolean = false,
    ): Boolean {
        if (backgroundedForMs <= 0L) return false
        if (callActive || transferActive || expectingReturn) return true
        return backgroundedForMs < delayMs
    }

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
     * A voice call or upload with the screen off looks exactly like an
     * abandoned app from the outside, and cutting its tunnel would drop it.
     */
    fun shouldDisconnectOnIdleAlarm(
        enabled: Boolean,
        phase: TailscaleOwnershipPhase,
        backgroundedForMs: Long,
        callActive: Boolean = false,
        transferActive: Boolean = false,
        delayMs: Long = IDLE_EXIT_DELAY_MS,
        expectingReturn: Boolean = false,
    ): Boolean {
        if (callActive || transferActive || expectingReturn) return false
        if (backgroundedForMs < delayMs) return false
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

    /**
     * The "switch off on exit" sync may raise a claim but never give one away.
     *
     * Handing the tunnel back is an explicit act — the user tapping disconnect,
     * or a check proving the tunnel is gone — and both go through
     * [TailscaleExit.releaseOwnership]. This path instead carries whatever phase
     * Dart happened to hold, which is UNOWNED whenever the platform channel
     * failed and handed back an empty snapshot. Letting that erase a live claim
     * is unrecoverable: with the tunnel still up, no later connect is ever
     * observed rising, so no new claim is recorded and exit stops switching the
     * tunnel off for good.
     */
    fun mayApplyPolicyPhaseWrite(
        current: TailscaleOwnershipPhase,
        incoming: TailscaleOwnershipPhase,
    ): Boolean = phaseRank(incoming) >= phaseRank(current)
}
