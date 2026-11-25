package com.example.call_dial

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat

object InCallNotificationHelper {
    private const val INCOMING_CHANNEL_ID = "leadpilot_incall_incoming_v1"
    private const val ONGOING_CHANNEL_ID = "leadpilot_incall_ongoing_v1"
    const val NOTIFICATION_ID = 98021

    private fun ensureChannels(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val incomingChannel = NotificationChannel(
                INCOMING_CHANNEL_ID,
                "Incoming Phone Calls",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "Full-screen incoming call notifications"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            val ongoingChannel = NotificationChannel(
                ONGOING_CHANNEL_ID,
                "Ongoing Phone Call",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Active call controls and duration"
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            manager.createNotificationChannel(incomingChannel)
            manager.createNotificationChannel(ongoingChannel)
        }
    }

    fun showIncomingCall(context: Context, callerName: String, phone: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        ensureChannels(manager)

        val fullScreenIntent = Intent(context, InCallActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val fullScreenPending = PendingIntent.getActivity(
            context,
            101,
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val answerIntent = Intent(context, InCallActionReceiver::class.java).apply {
            action = InCallActionReceiver.ACTION_ANSWER
        }
        val answerPending = PendingIntent.getBroadcast(
            context,
            102,
            answerIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val declineIntent = Intent(context, InCallActionReceiver::class.java).apply {
            action = InCallActionReceiver.ACTION_DECLINE
        }
        val declinePending = PendingIntent.getBroadcast(
            context,
            103,
            declineIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val builder = NotificationCompat.Builder(context, INCOMING_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(callerName)
            .setContentText(if (phone.isNotBlank() && phone != callerName) "Incoming call • $phone" else "Incoming call")
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setAutoCancel(false)
            .setContentIntent(fullScreenPending)
            .setFullScreenIntent(fullScreenPending, true)
            .addAction(R.drawable.ic_incall_call, "Answer", answerPending)
            .addAction(R.drawable.ic_incall_call_end, "Decline", declinePending)

        try {
            manager.notify(NOTIFICATION_ID, builder.build())
        } catch (_: SecurityException) {}
    }

    fun showOngoingCall(context: Context, callerName: String, phone: String, isHolding: Boolean) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        ensureChannels(manager)

        val openIntent = Intent(context, InCallActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        val openPending = PendingIntent.getActivity(
            context,
            104,
            openIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val endIntent = Intent(context, InCallActionReceiver::class.java).apply {
            action = InCallActionReceiver.ACTION_END
        }
        val endPending = PendingIntent.getBroadcast(
            context,
            105,
            endIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val subtitle = if (isHolding) "Call on hold • Tap to return" else "Ongoing call • Tap to return"

        val builder = NotificationCompat.Builder(context, ONGOING_CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(callerName)
            .setContentText(subtitle)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setUsesChronometer(!isHolding)
            .setContentIntent(openPending)
            .addAction(R.drawable.ic_incall_call_end, "End Call", endPending)

        try {
            manager.notify(NOTIFICATION_ID, builder.build())
        } catch (_: SecurityException) {}
    }

    fun cancel(context: Context) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        manager.cancel(NOTIFICATION_ID)
    }
}
