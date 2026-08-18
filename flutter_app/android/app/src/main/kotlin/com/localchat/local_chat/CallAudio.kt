package com.localchat.local_chat

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager

/**
 * Native call tones and in-call audio routing.
 *
 * Uses the device's default ringtone and ToneGenerator ringback — no bundled
 * copyrighted assets.
 */
class CallAudio(context: Context) {
    private val appContext = context.applicationContext
    private val audioManager =
        appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val handler = Handler(Looper.getMainLooper())

    private var ringtone: Ringtone? = null
    private var ringbackTone: ToneGenerator? = null
    private var ringbackRunnable: Runnable? = null
    private var vibrator: Vibrator? = null

    private var savedMode = AudioManager.MODE_NORMAL
    private var savedSpeaker = false
    private var savedSco = false
    private var prepared = false

    fun startIncomingAlert() {
        stopAlerts()
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            ringtone =
                RingtoneManager.getRingtone(appContext, uri)?.apply {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        audioAttributes =
                            AudioAttributes.Builder()
                                .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                .build()
                    }
                    play()
                }
        } catch (_: Exception) {
        }
        startVibration()
    }

    private fun startVibration() {
        vibrator =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val manager =
                    appContext.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                manager.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                appContext.getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
        val pattern = longArrayOf(0, 800, 400, 800, 400, 800)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
        } else {
            @Suppress("DEPRECATION")
            vibrator?.vibrate(pattern, 0)
        }
    }

    fun startRingback() {
        stopAlerts()
        try {
            ringbackTone = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 80)
            var on = true
            ringbackRunnable =
                object : Runnable {
                    override fun run() {
                        try {
                            if (on) {
                                ringbackTone?.startTone(
                                    ToneGenerator.TONE_CDMA_NETWORK_USA_RINGBACK,
                                    1000,
                                )
                            }
                            on = !on
                            handler.postDelayed(this, 2000)
                        } catch (_: Exception) {
                        }
                    }
                }
            handler.post(ringbackRunnable!!)
        } catch (_: Exception) {
        }
    }

    fun stopAlerts() {
        ringbackRunnable?.let { handler.removeCallbacks(it) }
        ringbackRunnable = null
        try {
            ringtone?.stop()
        } catch (_: Exception) {
        }
        ringtone = null
        try {
            ringbackTone?.release()
        } catch (_: Exception) {
        }
        ringbackTone = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
        vibrator = null
    }

    fun prepareForCall() {
        if (prepared) return
        savedMode = audioManager.mode
        savedSpeaker = audioManager.isSpeakerphoneOn
        savedSco = audioManager.isBluetoothScoOn
        audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
        if (!bluetoothActive()) {
            applyRoute(CallAudioPolicy.defaultRoute(listRoutes()))
        }
        prepared = true
    }

    fun restoreAudio() {
        stopAlerts()
        if (!prepared) return
        try {
            audioManager.isSpeakerphoneOn = savedSpeaker
            if (savedSco) {
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true
            } else {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
            }
            audioManager.mode = savedMode
        } catch (_: Exception) {
        }
        prepared = false
    }

    fun listRoutes(): List<String> =
        CallAudioPolicy.routesWithBluetooth(bluetoothAvailable())

    fun setRoute(route: String) {
        val normalized = CallAudioPolicy.normalizeRoute(route, listRoutes()) ?: return
        applyRoute(normalized)
    }

    private fun applyRoute(route: String) {
        when (route) {
            "speaker" -> {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
                audioManager.isSpeakerphoneOn = true
            }
            "earpiece" -> {
                audioManager.stopBluetoothSco()
                audioManager.isBluetoothScoOn = false
                audioManager.isSpeakerphoneOn = false
            }
            "bluetooth" -> {
                audioManager.isSpeakerphoneOn = false
                audioManager.startBluetoothSco()
                audioManager.isBluetoothScoOn = true
            }
        }
    }

    private fun bluetoothAvailable(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val devices = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
            return devices.any { device ->
                device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                    device.type == AudioDeviceInfo.TYPE_BLUETOOTH_A2DP ||
                    device.type == AudioDeviceInfo.TYPE_BLE_HEADSET
            }
        }
        @Suppress("DEPRECATION")
        return audioManager.isBluetoothScoAvailableOffCall
    }

    private fun bluetoothActive(): Boolean {
        if (audioManager.isBluetoothScoOn) return true
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            return audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { device ->
                device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO && device.isSink
            }
        }
        return false
    }
}
