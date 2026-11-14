package com.example.call_dial

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import android.provider.Settings
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
                        Log.d(TAG, "Matched student: ${student.name} (${student.phone}). Checking lock state to show single popup.")
                        lastShownNumber = incomingNumber

                        val keyguardManager = appContext.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
                        val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
                        val isScreenOn = powerManager?.isInteractive ?: true
                        val isLocked = (keyguardManager?.isKeyguardLocked == true) || !isScreenOn

                        if (isLocked) {
                            Log.d(TAG, "Device is locked/screen-off (isLocked=$isLocked). Launching single lock screen Caller ID.")
                            // Ensure WindowManager overlay is NOT displayed
                            CallerIdOverlayManager.dismiss(appContext)

                            // 1. Post Full-Screen Intent Notification (wakes up screen, launches CallerIdActivity via fullScreenIntent)
                            CallerIdNotificationHelper.show(appContext, student)

                            // 2. Also attempt direct transparent Activity start
                            CallerIdActivity.start(appContext, student)
                        } else {
                            Log.d(TAG, "Device is unlocked (isLocked=$isLocked). Displaying single floating overlay.")
                            // Dismiss lock screen activity
                            CallerIdActivity.dismissCurrent()

                            // Check overlay permission
                            if (Settings.canDrawOverlays(appContext)) {
                                // Cancel notification banner so only the floating overlay is visible
                                CallerIdNotificationHelper.cancel(appContext)
                                CallerIdOverlayManager.show(appContext, student)
                            } else {
                                // Fallback to notification banner if overlay permission not granted
                                CallerIdNotificationHelper.show(appContext, student)
                            }
                        }
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
