package com.example.call_dial

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager
import android.util.Log

class PhoneStateReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "PhoneStateReceiver"
        private var lastShownNumber: String? = null
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != TelephonyManager.ACTION_PHONE_STATE_CHANGED &&
            action != "android.intent.action.PHONE_STATE") {
            return
        }

        val appContext = context.applicationContext ?: context

        if (!CallerIdCacheManager.isCallerIdEnabled(appContext)) {
            Log.d(TAG, "Caller ID is disabled in settings. Skipping.")
            return
        }

        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
        Log.d(TAG, "PhoneStateReceiver received broadcast: action=$action, state=$state")

        if (state == null) return

        when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> {
                var incomingNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                if (incomingNumber.isNullOrEmpty()) {
                    incomingNumber = intent.extras?.getString("incoming_number")
                }
                if (incomingNumber.isNullOrEmpty()) {
                    incomingNumber = intent.extras?.getString("android.telephony.extra.INCOMING_NUMBER")
                }

                Log.d(TAG, "EXTRA_STATE_RINGING. Incoming number extracted: '$incomingNumber'")

                if (!incomingNumber.isNullOrEmpty()) {
                    // Prevent duplicate popups for the exact same ringing event
                    if (incomingNumber == lastShownNumber) {
                        Log.d(TAG, "Overlay already displayed for $incomingNumber. Skipping duplicate.")
                        return
                    }

                    val student = CallerIdCacheManager.lookupStudent(appContext, incomingNumber)
                    if (student != null) {
                        Log.d(TAG, "Matched student: ${student.name} (${student.phone}). Triggering lock screen and overlay displays.")
                        lastShownNumber = incomingNumber

                        // 1. Post Full-Screen Intent Notification (wakes up screen, displays on lock screen via Android NotificationManager)
                        CallerIdNotificationHelper.show(appContext, student)

                        // 2. Start transparent Activity with showWhenLocked
                        CallerIdActivity.start(appContext, student)

                        // 3. Show WindowManager floating overlay
                        CallerIdOverlayManager.show(appContext, student)
                    } else {
                        Log.d(TAG, "No student lead matched for number: $incomingNumber")
                    }
                } else {
                    Log.w(TAG, "Incoming number is null/empty. Check if READ_CALL_LOG permission is granted.")
                }
            }
            TelephonyManager.EXTRA_STATE_IDLE -> {
                Log.d(TAG, "EXTRA_STATE_IDLE: Phone call ended or idle. Dismissing all overlays/notifications.")
                lastShownNumber = null
                CallerIdNotificationHelper.cancel(appContext)
                CallerIdActivity.dismissCurrent()
                CallerIdOverlayManager.dismiss(appContext)
            }
            TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                Log.d(TAG, "EXTRA_STATE_OFFHOOK: Call answered. Keeping details visible for call.")
            }
        }
    }
}
