package com.example.call_dial

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat

object CallerIdNotificationHelper {
    private const val TAG = "CallerIdNotification"
    private const val CHANNEL_ID = "leadpilot_caller_id_channel_v2"
    private const val NOTIFICATION_ID = 8844

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                ?: return

            val existing = notificationManager.getNotificationChannel(CHANNEL_ID)
            if (existing == null) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Incoming Caller ID Alerts",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Displays incoming caller information on the lock screen and heads-up banner"
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                    setSound(null, null)
                    enableVibration(false)
                    enableLights(true)
                }
                notificationManager.createNotificationChannel(channel)
                Log.d(TAG, "Notification channel created: $CHANNEL_ID")
            }
        }
    }

    fun show(context: Context, student: StudentCallerInfo) {
        try {
            ensureChannel(context)

            // Wake up screen if turned off/asleep
            wakeUpScreen(context)

            val fullScreenIntent = Intent(context, CallerIdActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                putExtra("name", student.name)
                putExtra("phone", student.phone)
                putExtra("status", student.status)
                putExtra("location", student.location)
                putExtra("examType", student.examType)
                putExtra("examYear", student.examYear)
                putExtra("lastComment", student.lastComment)
                putExtra("streakCount", student.streakCount)
            }

            val flags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }

            val fullScreenPendingIntent = PendingIntent.getActivity(
                context,
                2026,
                fullScreenIntent,
                flags
            )

            val streakText = if (student.streakCount >= 3) " • ⚠️ ${student.streakCount}x No Answer" else ""
            val metaParts = listOf(student.examType, student.location).filter { it.isNotBlank() }.joinToString(" • ")
            val notePreview = if (student.lastComment.isNotBlank()) "💬 ${student.lastComment}" else "Registered Lead"

            val notification = NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("🎓 ${student.name} (${student.status})")
                .setContentText("$notePreview$streakText")
                .setStyle(
                    NotificationCompat.BigTextStyle().bigText(
                        "${if (metaParts.isNotBlank()) "$metaParts\n" else ""}$notePreview$streakText"
                    )
                )
                .setPriority(NotificationCompat.PRIORITY_MAX)
                .setCategory(NotificationCompat.CATEGORY_CALL)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setFullScreenIntent(fullScreenPendingIntent, true)
                .setContentIntent(fullScreenPendingIntent)
                .setAutoCancel(true)
                .setOngoing(true)
                .build()

            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            notificationManager?.notify(NOTIFICATION_ID, notification)
            Log.d(TAG, "Full-screen lock screen notification posted for ${student.name}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to show incoming call notification", e)
        }
    }

    fun cancel(context: Context) {
        try {
            val notificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            notificationManager?.cancel(NOTIFICATION_ID)
            Log.d(TAG, "Call notification cancelled")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to cancel notification", e)
        }
    }

    private fun wakeUpScreen(context: Context) {
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
            if (powerManager?.isInteractive == false) {
                @Suppress("DEPRECATION")
                val wakeLock = powerManager.newWakeLock(
                    PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP or PowerManager.ON_AFTER_RELEASE,
                    "LeadPilot:CallerIdWakeLock"
                )
                wakeLock.acquire(5000)
                Log.d(TAG, "WakeLock acquired to turn on screen")
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to acquire WakeLock", e)
        }
    }
}
