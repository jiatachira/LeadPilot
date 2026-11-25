package com.example.call_dial

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class InCallActionReceiver : BroadcastReceiver() {
    companion object {
        const val ACTION_ANSWER = "com.example.call_dial.ACTION_ANSWER_CALL"
        const val ACTION_DECLINE = "com.example.call_dial.ACTION_DECLINE_CALL"
        const val ACTION_END = "com.example.call_dial.ACTION_END_CALL"
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_ANSWER -> {
                LeadPilotCallManager.answer()
                InCallActivity.start(context)
            }
            ACTION_DECLINE -> {
                LeadPilotCallManager.rejectOrEnd()
            }
            ACTION_END -> {
                LeadPilotCallManager.rejectOrEnd()
            }
        }
    }
}
