package com.localchat.local_chat

/**
 * Mirrors Dart [callPhaseNeedsTunnelHold] — phases where a call must pin the
 * app-owned Tailscale tunnel even when the UI is in the background.
 */
object CallHoldPolicy {
    fun phaseNeedsTunnelHold(phase: String?): Boolean = when (phase) {
        "outgoing", "ringing", "incoming", "connecting", "active" -> true
        else -> false
    }
}
