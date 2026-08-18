package com.localchat.local_chat

/**
 * Durable record of whether Local Chat may disconnect Tailscale on exit.
 *
 * [UNOWNED] — nothing to switch off; a pre-existing tunnel or no claim.
 * [PENDING_CONNECT] — CONNECT_VPN was sent while routing was down; not owned yet.
 * [OWNED] — routing appeared after our connect request; exit may disconnect.
 */
enum class TailscaleOwnershipPhase(val wire: String) {
    UNOWNED("unowned"),
    PENDING_CONNECT("pending_connect"),
    OWNED("owned"),
    ;

    companion object {
        fun fromWire(value: String?): TailscaleOwnershipPhase =
            entries.firstOrNull { it.wire == value } ?: UNOWNED
    }
}
