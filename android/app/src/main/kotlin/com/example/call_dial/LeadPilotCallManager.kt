package com.example.call_dial

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService
import android.telecom.TelecomManager
import android.telecom.VideoProfile
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet

interface CallStateListener {
    fun onCallStateUpdated()
}

object LeadPilotCallManager {
    private const val TAG = "LeadPilotCallManager"

    var inCallService: InCallService? = null
    var primaryCall: Call? = null
        private set
    var secondaryCall: Call? = null
        private set
    var currentAudioState: CallAudioState? = null
        private set
    private val callConnectTimes = ConcurrentHashMap<Call, Long>()
    private val dtmfHandler = Handler(Looper.getMainLooper())
    val callConnectedAtMs: Long
        get() = primaryCall?.let { callConnectTimes[it] } ?: 0L

    private val listeners = CopyOnWriteArraySet<CallStateListener>()

    fun addListener(listener: CallStateListener) {
        listeners.add(listener)
    }

    fun removeListener(listener: CallStateListener) {
        listeners.remove(listener)
    }

    private fun notifyListeners() {
        for (listener in listeners) {
            try {
                listener.onCallStateUpdated()
            } catch (e: Exception) {
                Log.e(TAG, "Listener error", e)
            }
        }
    }

    fun isDefaultDialer(context: Context): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val tm = context.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                tm?.defaultDialerPackage == context.packageName
            } else {
                false
            }
        } catch (_: Exception) {
            false
        }
    }

    fun getPhoneNumber(call: Call?): String {
        if (call == null) return ""
        return try {
            call.details?.handle?.schemeSpecificPart?.trim() ?: ""
        } catch (_: Exception) {
            ""
        }
    }

    fun resolveCallerDisplay(context: Context, phone: String): Pair<String, StudentCallerInfo?> {
        if (phone.isBlank()) return Pair("Unknown Caller", null)
        val student = CallerIdCacheManager.lookupStudent(context, phone)
        if (student != null) {
            return Pair(student.name, student)
        }
        val contactName = lookupContactName(context, phone)
        if (!contactName.isNullOrBlank()) {
            return Pair(contactName, null)
        }
        return Pair(phone, null)
    }

    private fun lookupContactName(context: Context, phone: String): String? {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            return null
        }
        return try {
            val uri = Uri.withAppendedPath(
                ContactsContract.PhoneLookup.CONTENT_FILTER_URI,
                Uri.encode(phone)
            )
            context.contentResolver.query(
                uri,
                arrayOf(ContactsContract.PhoneLookup.DISPLAY_NAME),
                null,
                null,
                null
            )?.use { cursor ->
                if (cursor.moveToFirst()) {
                    cursor.getString(0)
                } else {
                    null
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private val callCallback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) {
            Log.d(TAG, "onStateChanged: ${getPhoneNumber(call)} -> $state")
            if (state == Call.STATE_ACTIVE && !callConnectTimes.containsKey(call)) {
                val systemConnectTime = call.details?.connectTimeMillis ?: 0L
                callConnectTimes[call] = if (systemConnectTime > 0L) systemConnectTime else System.currentTimeMillis()
            }
            if (call == primaryCall) {
                val service = inCallService
                if (service != null) {
                    val phone = getPhoneNumber(call)
                    val (displayName, _) = resolveCallerDisplay(service.applicationContext, phone)
                    when (state) {
                        Call.STATE_RINGING -> {
                            InCallNotificationHelper.showIncomingCall(service.applicationContext, displayName, phone)
                        }
                        Call.STATE_DIALING, Call.STATE_CONNECTING, Call.STATE_ACTIVE, Call.STATE_HOLDING -> {
                            InCallNotificationHelper.showOngoingCall(
                                service.applicationContext,
                                displayName,
                                phone,
                                isHolding = (state == Call.STATE_HOLDING)
                            )
                        }
                        Call.STATE_DISCONNECTED -> {
                            recordEndedCall(service.applicationContext, call)
                        }
                    }
                }
            } else if (state == Call.STATE_DISCONNECTED) {
                inCallService?.let { recordEndedCall(it.applicationContext, call) }
            }
            notifyListeners()
        }

        override fun onDetailsChanged(call: Call, details: Call.Details) {
            notifyListeners()
        }
    }

    private fun recordEndedCall(context: Context, call: Call) {
        val phone = getPhoneNumber(call)
        val connectedAt = callConnectTimes[call] ?: 0L
        if (phone.isNotBlank() && connectedAt > 0L) {
            val durationSec = ((System.currentTimeMillis() - connectedAt) / 1000L).coerceAtLeast(0L)
            val direction = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                if (call.details?.callDirection == Call.Details.DIRECTION_INCOMING) "incoming" else "outgoing"
            } else {
                "outgoing"
            }
            CallerIdCacheManager.addPendingCallLog(context, phone, durationSec, direction)
        }
    }

    fun onCallAdded(context: Context, call: Call) {
        call.registerCallback(callCallback)
        if (call.state == Call.STATE_ACTIVE && !callConnectTimes.containsKey(call)) {
            val systemConnectTime = call.details?.connectTimeMillis ?: 0L
            callConnectTimes[call] = if (systemConnectTime > 0L) systemConnectTime else System.currentTimeMillis()
        }
        if (primaryCall == null) {
            primaryCall = call
        } else if (secondaryCall == null && call != primaryCall) {
            secondaryCall = call
        }

        val phone = getPhoneNumber(call)
        val (displayName, _) = resolveCallerDisplay(context, phone)
        if (call.state == Call.STATE_RINGING) {
            InCallNotificationHelper.showIncomingCall(context, displayName, phone)
        } else {
            InCallNotificationHelper.showOngoingCall(
                context,
                displayName,
                phone,
                isHolding = (call.state == Call.STATE_HOLDING)
            )
        }
        notifyListeners()
    }

    fun onCallRemoved(context: Context, call: Call) {
        try {
            call.unregisterCallback(callCallback)
        } catch (_: Exception) {}
        callConnectTimes.remove(call)

        if (call == primaryCall) {
            primaryCall = secondaryCall
            secondaryCall = null
        } else if (call == secondaryCall) {
            secondaryCall = null
        }

        val remaining = primaryCall
        if (remaining == null) {
            dtmfHandler.removeCallbacksAndMessages(null)
            InCallNotificationHelper.cancel(context)
        } else {
            val phone = getPhoneNumber(remaining)
            val (displayName, _) = resolveCallerDisplay(context, phone)
            InCallNotificationHelper.showOngoingCall(
                context,
                displayName,
                phone,
                isHolding = (remaining.state == Call.STATE_HOLDING)
            )
        }
        notifyListeners()
    }

    fun onAudioStateChanged(audioState: CallAudioState?) {
        currentAudioState = audioState
        notifyListeners()
    }

    fun answer() {
        primaryCall?.answer(VideoProfile.STATE_AUDIO_ONLY)
    }

    fun rejectOrEnd() {
        val call = primaryCall ?: return
        if (call.state == Call.STATE_RINGING) {
            call.reject(false, null)
        } else {
            call.disconnect()
        }
    }

    fun toggleMute() {
        val muted = currentAudioState?.isMuted ?: false
        inCallService?.setMuted(!muted)
    }

    fun toggleSpeaker() {
        val route = currentAudioState?.route ?: CallAudioState.ROUTE_EARPIECE
        if (route == CallAudioState.ROUTE_SPEAKER) {
            val hasBt = ((currentAudioState?.supportedRouteMask ?: 0) and CallAudioState.ROUTE_BLUETOOTH) != 0
            inCallService?.setAudioRoute(
                if (hasBt) CallAudioState.ROUTE_BLUETOOTH else CallAudioState.ROUTE_WIRED_OR_EARPIECE
            )
        } else {
            inCallService?.setAudioRoute(CallAudioState.ROUTE_SPEAKER)
        }
    }

    fun toggleBluetooth() {
        val route = currentAudioState?.route ?: CallAudioState.ROUTE_EARPIECE
        val supported = currentAudioState?.supportedRouteMask ?: 0
        if ((supported and CallAudioState.ROUTE_BLUETOOTH) == 0) return
        if (route == CallAudioState.ROUTE_BLUETOOTH) {
            inCallService?.setAudioRoute(CallAudioState.ROUTE_WIRED_OR_EARPIECE)
        } else {
            inCallService?.setAudioRoute(CallAudioState.ROUTE_BLUETOOTH)
        }
    }

    fun toggleHold() {
        val call = primaryCall ?: return
        if (call.state == Call.STATE_HOLDING) {
            call.unhold()
        } else if (call.state == Call.STATE_ACTIVE) {
            call.hold()
        }
    }

    fun handleSecondaryAction() {
        val sec = secondaryCall ?: return
        if (sec.state == Call.STATE_RINGING) {
            primaryCall?.hold()
            sec.answer(VideoProfile.STATE_AUDIO_ONLY)
            val oldPrimary = primaryCall
            primaryCall = sec
            secondaryCall = oldPrimary
        } else {
            // Swap active and holding calls
            val oldPrimary = primaryCall
            if (oldPrimary?.state == Call.STATE_ACTIVE) {
                oldPrimary.hold()
            }
            if (sec.state == Call.STATE_HOLDING) {
                sec.unhold()
            }
            primaryCall = sec
            secondaryCall = oldPrimary
        }
        notifyListeners()
    }

    fun rejectSecondaryCall() {
        val sec = secondaryCall ?: return
        if (sec.state == Call.STATE_RINGING) {
            sec.reject(false, null)
        } else {
            sec.disconnect()
        }
    }

    fun playDtmf(digit: Char) {
        val call = primaryCall ?: return
        dtmfHandler.removeCallbacksAndMessages(null)
        call.stopDtmfTone()
        call.playDtmfTone(digit)
        dtmfHandler.postDelayed({
            try {
                call.stopDtmfTone()
            } catch (_: Exception) {}
        }, 180L)
    }
}
