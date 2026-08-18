package com.localchat.local_chat

/** Pure audio-route helpers for unit tests (no Android framework). */
object CallAudioPolicy {
    val knownRoutes = setOf("earpiece", "speaker", "bluetooth")

    fun normalizeRoute(route: String?, available: Collection<String>): String? {
        if (route == null) return null
        if (route !in knownRoutes) return null
        return route.takeIf { it in available }
    }

    /** Route order every call starts on: a headset first, then the ear, then the room.
     *
     * Video calls used to open on the speaker, which announced the call to
     * whoever else was in the room and ignored a connected headset. The kind of
     * call no longer changes where the sound goes; only the user does.
     */
    val routePriority = listOf("bluetooth", "earpiece", "speaker")

    fun defaultRoute(available: Collection<String>): String =
        routePriority.firstOrNull { it in available } ?: available.firstOrNull() ?: "earpiece"

    fun routesWithBluetooth(bluetoothAvailable: Boolean): List<String> =
        if (bluetoothAvailable) listOf("earpiece", "speaker", "bluetooth")
        else listOf("earpiece", "speaker")
}
