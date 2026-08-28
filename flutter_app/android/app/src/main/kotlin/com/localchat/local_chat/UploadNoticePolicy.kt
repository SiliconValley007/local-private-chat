package com.localchat.local_chat

/**
 * What the upload notification says, and when it is worth redrawing.
 *
 * Kept free of Android types so the arithmetic that a user actually reads —
 * percentages that never show 101%, sizes in units people use, and a refresh
 * rate that does not post a hundred notifications a second — can be tested
 * without a device.
 */
object UploadNoticePolicy {

    /** Redraw at most this often, however fast the bytes are moving. */
    const val MIN_REFRESH_MS = 500L

    /**
     * Progress as a whole percentage, clamped into 0..100.
     *
     * A total of zero happens for an empty file and for a send whose size is not
     * known yet; both read better as "just started" than as a division by zero.
     */
    fun percent(sent: Long, total: Long): Int {
        if (total <= 0L) return 0
        val ratio = sent.toDouble() / total.toDouble() * 100.0
        return ratio.toInt().coerceIn(0, 100)
    }

    /**
     * True when the notification should be posted again.
     *
     * Progress notifications are cheap but not free, and Android drops updates
     * that arrive too fast anyway. Redrawing on a changed percentage or after
     * half a second keeps a 500 MB send visibly moving without the churn.
     */
    fun shouldRedraw(
        lastPercent: Int,
        percent: Int,
        lastDrawnAtMs: Long,
        nowMs: Long,
    ): Boolean {
        if (lastDrawnAtMs <= 0L) return true
        if (percent >= 100 && lastPercent < 100) return true
        if (percent != lastPercent) return nowMs - lastDrawnAtMs >= MIN_REFRESH_MS
        return nowMs - lastDrawnAtMs >= 5_000L
    }

    /** A size in the units a person would use, without noisy decimals. */
    fun humanBytes(bytes: Long): String {
        val safe = if (bytes < 0L) 0L else bytes
        val kb = 1024.0
        val mb = kb * 1024.0
        val gb = mb * 1024.0
        return when {
            safe >= gb -> String.format("%.1f GB", safe / gb)
            safe >= mb -> String.format("%.0f MB", safe / mb)
            safe >= kb -> String.format("%.0f KB", safe / kb)
            else -> "$safe B"
        }
    }

    /**
     * The line under the title: how far along, in bytes people recognise.
     *
     * While the total is unknown only what has gone is shown, because "0 of 0"
     * reads like a send that is stuck.
     */
    fun progressLine(sent: Long, total: Long): String {
        if (total <= 0L) return humanBytes(sent)
        val done = if (sent > total) total else sent
        return "${humanBytes(done)} of ${humanBytes(total)} · ${percent(done, total)}%"
    }

    /** The notification title, naming the file when there is a name to use. */
    fun title(fileLabel: String?, remainingCount: Int): String {
        val label = fileLabel?.trim().orEmpty()
        return when {
            remainingCount > 1 -> "Sending $remainingCount attachments"
            label.isNotEmpty() -> "Sending $label"
            else -> "Sending attachment"
        }
    }
}
