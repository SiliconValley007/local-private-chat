package com.localchat.local_chat

import android.content.Intent
import android.graphics.Bitmap
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

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        // Previous run may have owned the tunnel but died before DISCONNECT_VPN.
        TailscaleExit.retryInterruptedDisconnectIfNeeded(this)
    }

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
                        result.success(null)
                    }
                    "restoreAudio" -> {
                        audio.restoreAudio()
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
        // Re-armed on every resume: Android stops background services a while
        // after an app leaves the foreground, and a stopped service would never
        // hear onTaskRemoved when the user finally swipes the app away.
        try {
            startService(Intent(this, ExitWatcherService::class.java))
        } catch (e: Exception) {
            Log.w("MainActivity", "Exit watcher not started: ${e.message}")
        }
    }

    override fun onDestroy() {
        // isFinishing separates a real close from a rotation or config change.
        if (isFinishing) {
            callAudio?.restoreAudio()
            TailscaleExit.disconnectIfAllowed(this, "activity finishing")
        }
        super.onDestroy()
    }

}
