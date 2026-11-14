package com.example.call_dial

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.TelephonyManager
import android.util.Log

class PhoneStateReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "PhoneStateReceiver"
        private var lastState = TelephonyManager.EXTRA_STATE_IDLE
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action != TelephonyManager.ACTION_PHONE_STATE_CHANGED &&
            action != "android.intent.action.PHONE_STATE") {
            return
        }

        if (!CallerIdCacheManager.isCallerIdEnabled(context)) {
            Log.d(TAG, "Caller ID is disabled in settings. Skipping.")
            return
        }

        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE) ?: return
        if (state == lastState) {
            return
        }
        lastState = state

        Log.d(TAG, "Phone state changed: $state")

        when (state) {
            TelephonyManager.EXTRA_STATE_RINGING -> {
                var incomingNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
                if (incomingNumber.isNullOrEmpty()) {
                    incomingNumber = intent.extras?.getString("incoming_number")
                }
                Log.d(TAG, "Incoming ringing call from: $incomingNumber")

                if (!incomingNumber.isNullOrEmpty()) {
                    val student = CallerIdCacheManager.lookupStudent(context, incomingNumber)
                    if (student != null) {
                        Log.d(TAG, "Matched student: ${student.name}")
                        CallerIdOverlayManager.show(context, student)
                    } else {
                        Log.d(TAG, "No matching student for: $incomingNumber")
                    }
                }
            }
            TelephonyManager.EXTRA_STATE_IDLE -> {
                Log.d(TAG, "Phone is idle, dismissing overlay")
                CallerIdOverlayManager.dismiss(context)
            }
        }
    }
}
