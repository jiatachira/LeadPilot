package com.example.call_dial

import android.media.AudioAttributes
import android.media.AudioManager
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.media.Ringtone
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.example.call_dial/ringtone"
    private var ringtone: Ringtone? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playRingtone" -> {
                        try {
                            stopCurrentRingtone()
                            val uri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                            val r = RingtoneManager.getRingtone(applicationContext, uri)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                r?.isLooping = true
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                r?.audioAttributes = AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                    .build()
                            } else {
                                @Suppress("DEPRECATION")
                                r?.streamType = AudioManager.STREAM_RING
                            }
                            r?.play()
                            ringtone = r
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("RINGTONE_ERROR", e.message, null)
                        }
                    }
                    "stopRingtone" -> {
                        try {
                            stopCurrentRingtone()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("RINGTONE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun stopCurrentRingtone() {
        ringtone?.let {
            if (it.isPlaying) it.stop()
        }
        ringtone = null
    }

    override fun onDestroy() {
        stopCurrentRingtone()
        super.onDestroy()
    }
}
