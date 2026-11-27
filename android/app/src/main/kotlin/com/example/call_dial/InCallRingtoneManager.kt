package com.example.call_dial

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.Log

object InCallRingtoneManager {
    private const val TAG = "InCallRingtoneManager"
    private var ringtone: Ringtone? = null
    private var vibrator: Vibrator? = null
    private var isRinging = false
    private val mainHandler = Handler(Looper.getMainLooper())

    private val loopCheckRunnable = object : Runnable {
        override fun run() {
            if (!isRinging) return
            try {
                ringtone?.let {
                    if (!it.isPlaying) {
                        it.play()
                    }
                }
            } catch (_: Exception) {}
            if (isRinging) {
                mainHandler.postDelayed(this, 1000L)
            }
        }
    }

    fun startRinging(context: Context) {
        mainHandler.post {
            if (isRinging) return@post
            try {
                val app = context.applicationContext ?: context
                val audioManager = app.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                val ringerMode = audioManager?.ringerMode ?: AudioManager.RINGER_MODE_NORMAL

                if (ringerMode == AudioManager.RINGER_MODE_SILENT) {
                    Log.d(TAG, "Ringer mode is silent. Skipping sound and vibration.")
                    isRinging = true
                    return@post
                }

                startVibration(app)

                if (ringerMode == AudioManager.RINGER_MODE_NORMAL) {
                    val uri: Uri = RingtoneManager.getActualDefaultRingtoneUri(app, RingtoneManager.TYPE_RINGTONE)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                        ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)

                    val r = RingtoneManager.getRingtone(app, uri)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        r?.isLooping = true
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                        r?.audioAttributes = AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .setLegacyStreamType(AudioManager.STREAM_RING)
                            .build()
                    } else {
                        @Suppress("DEPRECATION")
                        r?.streamType = AudioManager.STREAM_RING
                    }
                    r?.play()
                    ringtone = r

                    mainHandler.removeCallbacks(loopCheckRunnable)
                    mainHandler.postDelayed(loopCheckRunnable, 1000L)
                    Log.d(TAG, "Incoming call ringtone started playing")
                }

                isRinging = true
            } catch (e: Exception) {
                Log.e(TAG, "Error starting ringtone", e)
            }
        }
    }

    private fun startVibration(context: Context) {
        try {
            val v = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            }
            vibrator = v

            val pattern = longArrayOf(0, 1000, 1000)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                v?.vibrate(VibrationEffect.createWaveform(pattern, 1))
            } else {
                @Suppress("DEPRECATION")
                v?.vibrate(pattern, 1)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error starting vibration", e)
        }
    }

    fun stopRinging(context: Context? = null) {
        mainHandler.post {
            isRinging = false
            mainHandler.removeCallbacks(loopCheckRunnable)

            try {
                ringtone?.let {
                    if (it.isPlaying) {
                        it.stop()
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Error stopping ringtone", e)
            } finally {
                ringtone = null
            }

            try {
                vibrator?.cancel()
            } catch (e: Exception) {
                Log.e(TAG, "Error cancelling vibration", e)
            } finally {
                vibrator = null
            }

            Log.d(TAG, "Incoming call ringtone stopped")
        }
    }
}
