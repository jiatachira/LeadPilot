package com.example.call_dial

import android.content.Intent
import android.os.IBinder
import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.util.Log

class LeadPilotInCallService : InCallService() {
    companion object {
        private const val TAG = "LeadPilotInCallService"
    }

    override fun onBind(intent: Intent?): IBinder? {
        LeadPilotCallManager.inCallService = this
        Log.d(TAG, "LeadPilotInCallService bound.")
        return super.onBind(intent)
    }

    override fun onUnbind(intent: Intent?): Boolean {
        if (LeadPilotCallManager.inCallService == this) {
            LeadPilotCallManager.inCallService = null
        }
        Log.d(TAG, "LeadPilotInCallService unbound.")
        return super.onUnbind(intent)
    }

    override fun onCallAdded(call: Call) {
        super.onCallAdded(call)
        Log.d(TAG, "onCallAdded: ${LeadPilotCallManager.getPhoneNumber(call)} state=${call.state}")
        LeadPilotCallManager.inCallService = this
        LeadPilotCallManager.onCallAdded(applicationContext, call)
        InCallActivity.start(applicationContext)
    }

    override fun onCallRemoved(call: Call) {
        super.onCallRemoved(call)
        Log.d(TAG, "onCallRemoved: ${LeadPilotCallManager.getPhoneNumber(call)}")
        LeadPilotCallManager.onCallRemoved(applicationContext, call)
    }

    override fun onCallAudioStateChanged(audioState: CallAudioState?) {
        super.onCallAudioStateChanged(audioState)
        LeadPilotCallManager.onAudioStateChanged(audioState)
    }
}
