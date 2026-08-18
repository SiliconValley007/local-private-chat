package com.localchat.local_chat

/** Pure audio-route helpers for unit tests (no Android framework). */
object CallAudioPolicy {
    val knownRoutes = setOf("earpiece", "speaker", "bluetooth")

    fun normalizeRoute(route: String?, available: Collection<String>): String? {
        if (route == null) return null
        if (route !in knownRoutes) return null
        return route.takeIf { it in available }
    }

    fun defaultRoute(isVideo: Boolean, available: Collection<String>): String {
        val preferred = if (isVideo) "speaker" else "earpiece"
        if (preferred in available) return preferred
        return available.firstOrNull() ?: "earpiece"
    }

    fun routesWithBluetooth(bluetoothAvailable: Boolean): List<String> =
        if (bluetoothAvailable) listOf("earpiece", "speaker", "bluetooth")
        else listOf("earpiece", "speaker")
}
