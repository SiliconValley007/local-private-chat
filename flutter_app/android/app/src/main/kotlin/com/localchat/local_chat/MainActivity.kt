package com.localchat.local_chat

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    private var incomingChannel: MethodChannel? = null
    private var callAudio: CallAudio? = null

    /// Held when a share arrives before Dart is listening — a cold start from the
    /// share sheet always lands here first. Dart drains it with "getInitial".
    private var pendingIncoming: Map<String, Any?>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        incomingChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IncomingIntents.CHANNEL)
                .apply {
                    setMethodCallHandler { call, result ->
                        when (call.method) {
                            "getInitial" -> {
                                result.success(pendingIncoming)
                                pendingIncoming = null
                            }
                            else -> result.notImplemented()
                        }
                    }
                }
        handleIncoming(intent, fromNewIntent = false)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "local_chat/call_audio")
            .setMethodCallHandler { call, result ->
                val audio = callAudio ?: CallAudio(this).also { callAudio = it }
                when (call.method) {
                    "startIncomingAlert" -> {
                        audio.startIncomingAlert()
                        result.success(null)
                    }
                    "startRingback" -> {
                        audio.startRingback()
                        result.success(null)
                    }
                    "stopAlerts" -> {
                        audio.stopAlerts()
                        result.success(null)
                    }
                    "prepareForCall" -> {
                        val isVideo = call.argument<Boolean>("isVideo") ?: false
                        audio.prepareForCall(isVideo)
                        // A call with the screen off must keep its tunnel.
                        AppForeground.noteCall(true)
                        result.success(null)
                    }
                    "restoreAudio" -> {
                        audio.restoreAudio()
                        AppForeground.noteCall(false)
                        result.success(null)
                    }
                    "listRoutes" -> result.success(audio.listRoutes())
                    "setRoute" -> {
                        val route = call.argument<String>("route") ?: ""
                        audio.setRoute(route)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TailscaleExit.CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setExitPolicy" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val phaseWire = call.argument<String>("phase")
                        val phase = if (phaseWire != null) {
                            TailscaleOwnershipPhase.fromWire(phaseWire)
                        } else if (call.argument<Boolean>("startedByApp") == true) {
                            TailscaleOwnershipPhase.OWNED
                        } else {
                            TailscaleOwnershipPhase.UNOWNED
                        }
                        TailscaleExit.savePolicy(this, enabled, phase)
                        result.success(null)
                    }
                    "getExitPolicy" -> result.success(TailscaleExit.readPolicy(this))
                    "requestConnect" -> {
                        val routingWasDown =
                            call.argument<Boolean>("routingWasDown") ?: false
                        val routingAlreadyUp =
                            call.argument<Boolean>("routingAlreadyUp") ?: false
                        val sent = TailscaleExit.requestConnect(
                            this,
                            routingWasDown,
                            routingAlreadyUp,
                        )
                        result.success(sent)
                    }
                    "markOwned" -> {
                        TailscaleExit.markOwned(this)
                        result.success(null)
                    }
                    "releaseOwnership" -> {
                        TailscaleExit.releaseOwnership(
                            this,
                            call.argument<String>("reason") ?: "dart",
                        )
                        result.success(null)
                    }
                    "disconnectNow" -> {
                        TailscaleExit.disconnectNow(this, "manual")
                        result.success(null)
                    }
                    "disconnectIfAllowed" -> {
                        TailscaleExit.disconnectIfAllowed(this, "app leaving")
                        result.success(null)
                    }
                    "retryInterruptedDisconnect" -> {
                        TailscaleExit.retryInterruptedDisconnectIfNeeded(this)
                        result.success(null)
                    }
                    "noteTransfer" -> {
                        val active = call.argument<Boolean>("active") ?: false
                        AppForeground.noteTransfer(active)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "local_chat/video_thumbnail")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "create" -> {
                        val path = call.argument<String>("path")
                        val maxWidth = call.argument<Int>("maxWidth") ?: 480
                        val quality = call.argument<Int>("quality") ?: 72
                        if (path.isNullOrEmpty()) {
                            result.error("INVALID_ARGUMENT", "Video path is null", null)
                            return@setMethodCallHandler
                        }
                        result.success(createVideoThumbnail(path, maxWidth, quality))
                    }
                    "createImage" -> {
                        val path = call.argument<String>("path")
                        val maxWidth = call.argument<Int>("maxWidth") ?: 720
                        val quality = call.argument<Int>("quality") ?: 78
                        if (path.isNullOrEmpty()) {
                            result.error("INVALID_ARGUMENT", "Image path is null", null)
                            return@setMethodCallHandler
                        }
                        result.success(createImageThumbnail(path, maxWidth, quality))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    /// Decodes the first visible frame with Android's own extractor and writes a
    /// small JPEG into the cache, and reads the clip's duration in the same pass.
    /// Returns a map of {path, durationMs}; either value may be null (not an
    /// error) when the codec cannot produce it, so the caller degrades to a
    /// plain video tile.
    private fun createVideoThumbnail(
        path: String,
        maxWidth: Int,
        quality: Int,
    ): Map<String, Any?> {
        val retriever = MediaMetadataRetriever()
        var thumbPath: String? = null
        var durationMs: Long? = null
        try {
            retriever.setDataSource(path)
            durationMs = retriever
                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                ?.toLongOrNull()
            val frame = retriever.frameAtTime
            if (frame != null) {
                val scaled = scaleToWidth(frame, maxWidth)
                val out = File(cacheDir, "vthumb_${System.currentTimeMillis()}.jpg")
                FileOutputStream(out).use { stream ->
                    scaled.compress(Bitmap.CompressFormat.JPEG, quality, stream)
                }
                if (scaled != frame) scaled.recycle()
                frame.recycle()
                thumbPath = out.absolutePath
            }
        } catch (e: Exception) {
            Log.w("MainActivity", "Thumbnail failed: ${e.message}")
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
        return mapOf("path" to thumbPath, "durationMs" to durationMs)
    }

    private fun scaleToWidth(source: Bitmap, maxWidth: Int): Bitmap {
        if (source.width <= maxWidth || source.width == 0) return source
        val ratio = maxWidth.toFloat() / source.width.toFloat()
        val height = (source.height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(source, maxWidth, height, true)
    }

    /** Downsamples a gallery photo before decoding, then stores a small JPEG. */
    private fun createImageThumbnail(
        path: String,
        maxWidth: Int,
        quality: Int,
    ): Map<String, Any?> {
        return try {
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(path, bounds)
            if (bounds.outWidth <= 0 || bounds.outHeight <= 0) {
                return mapOf("path" to null)
            }
            var sample = 1
            while (bounds.outWidth / (sample * 2) >= maxWidth) sample *= 2
            val decoded = BitmapFactory.decodeFile(
                path,
                BitmapFactory.Options().apply { inSampleSize = sample },
            ) ?: return mapOf("path" to null)
            val scaled = scaleToWidth(decoded, maxWidth)
            val out = File(cacheDir, "ithumb_${System.currentTimeMillis()}.jpg")
            FileOutputStream(out).use { stream ->
                scaled.compress(Bitmap.CompressFormat.JPEG, quality, stream)
            }
            if (scaled != decoded) scaled.recycle()
            decoded.recycle()
            mapOf("path" to out.absolutePath)
        } catch (e: Exception) {
            Log.w("MainActivity", "Image thumbnail failed: ${e.message}")
            mapOf("path" to null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncoming(intent, fromNewIntent = true)
    }

    /// Pushes a share or deep link to Dart, or parks it until Dart asks.
    private fun handleIncoming(intent: Intent?, fromNewIntent: Boolean) {
        val payload = IncomingIntents.parse(this, intent) ?: return
        // Consumed here so a config change or a return to the activity cannot
        // replay the same share and send it twice.
        intent?.action = Intent.ACTION_MAIN
        intent?.removeExtra(Intent.EXTRA_TEXT)
        intent?.removeExtra(Intent.EXTRA_STREAM)
        val channel = incomingChannel
        if (channel != null && fromNewIntent) {
            channel.invokeMethod("onIntent", payload)
        } else {
            pendingIncoming = payload
        }
    }

    override fun onResume() {
        super.onResume()
        AppForeground.markResumed()
        // The user is back, so the background timer that would have dropped the
        // tunnel is no longer wanted.
        TailscaleIdleExit.cancel(this)
        // Started from a resumed activity, the one state in which starting a
        // service is always allowed. It is the guard, not this activity, that
        // closes the tunnel once the app has been away for a while.
        TailscaleGuardService.watch(this)
    }

    override fun onStop() {
        AppForeground.markStopped()
        // Belt to the guard's braces: an alarm for the case this process is gone
        // before the guard's own countdown gets there.
        if (!isFinishing) TailscaleIdleExit.arm(this)
        super.onStop()
    }

    override fun onDestroy() {
        // isFinishing separates a real close from a rotation or config change.
        if (isFinishing) {
            val wasInCall = AppForeground.callStillActive()
            val wasTransferring = AppForeground.transferStillActive()
            callAudio?.restoreAudio()
            AppForeground.noteCall(false)
            // Leave transferActive alone here: Dart clears it in finally. If the
            // process is dying mid-upload, the idle alarm is the backstop.
            if (wasInCall || wasTransferring) {
                // Closing the task ends the work too, but let teardown finish
                // before the process-death-safe alarm drops the tunnel.
                TailscaleIdleExit.arm(this)
            } else {
                // onStop deliberately skips arming while isFinishing, so make
                // sure even a direct close from the foreground gets a fallback.
                TailscaleIdleExit.arm(this)
                TailscaleExit.disconnectIfAllowed(this, "activity finishing")
                // Do not cancel the background alarm here. DISCONNECT_VPN has
                // no acknowledgement, so that later delivery is the fallback
                // if Tailscale ignored this immediate best-effort broadcast.
            }
        }
        super.onDestroy()
    }

}
