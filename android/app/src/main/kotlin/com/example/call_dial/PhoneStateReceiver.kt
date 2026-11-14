package com.example.call_dial

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
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
                        Log.d(TAG, "Matched student: ${student.name} (${student.phone})")
                        lastShownNumber = incomingNumber

                        val keyguardManager = appContext.getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
                        val powerManager = appContext.getSystemService(Context.POWER_SERVICE) as? PowerManager
                        val isLocked = keyguardManager?.isKeyguardLocked == true || powerManager?.isInteractive == false

                        if (isLocked) {
                            Log.d(TAG, "Screen is locked/off. Starting CallerIdActivity for lockscreen.")
                            CallerIdActivity.start(appContext, student)
                        } else {
                            Log.d(TAG, "Screen is active and unlocked. Showing WindowManager overlay.")
                            CallerIdOverlayManager.show(appContext, student)
                        }
                    } else {
                        Log.d(TAG, "No student lead matched for number: $incomingNumber")
                    }
                } else {
                    Log.w(TAG, "Incoming number is null/empty. Check if READ_CALL_LOG permission is granted.")
                }
            }
            TelephonyManager.EXTRA_STATE_IDLE -> {
                Log.d(TAG, "EXTRA_STATE_IDLE: Phone call ended or idle. Dismissing all overlays/activities.")
                lastShownNumber = null
                CallerIdActivity.dismissCurrent()
                CallerIdOverlayManager.dismiss(appContext)
            }
            TelephonyManager.EXTRA_STATE_OFFHOOK -> {
                Log.d(TAG, "EXTRA_STATE_OFFHOOK: Call answered. Keeping details visible for call.")
            }
        }
    }
}
