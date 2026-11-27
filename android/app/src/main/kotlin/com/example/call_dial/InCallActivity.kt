package com.example.call_dial

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.telecom.Call
import android.telecom.CallAudioState
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.GridLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView

class InCallActivity : Activity(), CallStateListener {
    companion object {
        private const val TAG = "InCallActivity"

        fun start(context: Context) {
            try {
                val intent = Intent(context, InCallActivity::class.java).apply {
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                    )
                }
                context.startActivity(intent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start InCallActivity", e)
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private var proximityWakeLock: PowerManager.WakeLock? = null
    private var isKeypadVisible = false
    private val dtmfBuffer = StringBuilder()

    // UI references
    private lateinit var tvStatusBadge: TextView
    private lateinit var tvAvatar: TextView
    private lateinit var tvName: TextView
    private lateinit var tvPhone: TextView
    private lateinit var tvTimer: TextView

    private lateinit var studentCard: LinearLayout
    private lateinit var tvStudentMeta: TextView
    private lateinit var tvStudentStreak: TextView
    private lateinit var tvStudentComment: TextView

    private lateinit var secondaryBanner: LinearLayout
    private lateinit var tvSecondaryTitle: TextView
    private lateinit var tvSecondaryName: TextView
    private lateinit var btnSecondaryAction: TextView
    private lateinit var btnSecondaryReject: TextView

    private lateinit var controlsGrid: LinearLayout
    private lateinit var btnMute: ImageButton
    private lateinit var lblMute: TextView
    private lateinit var btnKeypad: ImageButton
    private lateinit var btnSpeaker: ImageButton
    private lateinit var lblSpeaker: TextView
    private lateinit var btnHold: ImageButton
    private lateinit var lblHold: TextView
    private lateinit var btnOpenApp: ImageButton
    private lateinit var btnAudio: ImageButton
    private lateinit var lblAudio: TextView
    private lateinit var btnRecord: ImageButton
    private lateinit var lblRecord: TextView

    private lateinit var dtmfPanel: LinearLayout
    private lateinit var tvDtmfDigits: TextView
    private lateinit var btnHideKeypad: TextView
    private lateinit var dtmfGrid: GridLayout

    private lateinit var incomingActions: LinearLayout
    private lateinit var activeActions: LinearLayout
    private lateinit var btnDecline: ImageButton
    private lateinit var btnAnswer: ImageButton
    private lateinit var btnEnd: ImageButton

    private val timerTick = object : Runnable {
        override fun run() {
            updateTimerText()
            handler.postDelayed(this, 1000L)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setupLockScreenFlags()
        setContentView(R.layout.activity_in_call)
        bindViews()
        setupDtmfKeypad()
        setupButtonListeners()
        LeadPilotCallManager.addListener(this)
        updateUi()
        handler.post(timerTick)
    }

    private fun setupLockScreenFlags() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun bindViews() {
        tvStatusBadge = findViewById(R.id.incall_status_badge)
        tvAvatar = findViewById(R.id.incall_avatar)
        tvName = findViewById(R.id.incall_name)
        tvPhone = findViewById(R.id.incall_phone)
        tvTimer = findViewById(R.id.incall_timer)

        studentCard = findViewById(R.id.incall_student_card)
        tvStudentMeta = findViewById(R.id.incall_student_meta)
        tvStudentStreak = findViewById(R.id.incall_student_streak)
        tvStudentComment = findViewById(R.id.incall_student_comment)

        secondaryBanner = findViewById(R.id.incall_secondary_banner)
        tvSecondaryTitle = findViewById(R.id.incall_secondary_title)
        tvSecondaryName = findViewById(R.id.incall_secondary_name)
        btnSecondaryAction = findViewById(R.id.incall_btn_secondary_action)
        btnSecondaryReject = findViewById(R.id.incall_btn_secondary_reject)

        controlsGrid = findViewById(R.id.incall_controls_grid)
        btnMute = findViewById(R.id.incall_btn_mute)
        lblMute = findViewById(R.id.incall_lbl_mute)
        btnKeypad = findViewById(R.id.incall_btn_keypad)
        btnSpeaker = findViewById(R.id.incall_btn_speaker)
        lblSpeaker = findViewById(R.id.incall_lbl_speaker)
        btnHold = findViewById(R.id.incall_btn_hold)
        lblHold = findViewById(R.id.incall_lbl_hold)
        btnOpenApp = findViewById(R.id.incall_btn_open_app)
        btnAudio = findViewById(R.id.incall_btn_audio)
        lblAudio = findViewById(R.id.incall_lbl_audio)
        btnRecord = findViewById(R.id.incall_btn_record)
        lblRecord = findViewById(R.id.incall_lbl_record)

        dtmfPanel = findViewById(R.id.incall_dtmf_panel)
        tvDtmfDigits = findViewById(R.id.incall_dtmf_digits)
        btnHideKeypad = findViewById(R.id.incall_btn_hide_keypad)
        dtmfGrid = findViewById(R.id.incall_dtmf_grid)

        incomingActions = findViewById(R.id.incall_incoming_actions)
        activeActions = findViewById(R.id.incall_active_actions)
        btnDecline = findViewById(R.id.incall_btn_decline)
        btnAnswer = findViewById(R.id.incall_btn_answer)
        btnEnd = findViewById(R.id.incall_btn_end)
    }

    private fun setupDtmfKeypad() {
        val keys = listOf(
            "1", "2", "3",
            "4", "5", "6",
            "7", "8", "9",
            "*", "0", "#"
        )
        for (k in keys) {
            val btn = TextView(this).apply {
                text = k
                gravity = Gravity.CENTER
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 22f)
                setTypeface(null, android.graphics.Typeface.BOLD)
                setPadding(0, 22, 0, 22)
                isClickable = true
                isFocusable = true
                setOnClickListener {
                    dtmfBuffer.append(k)
                    tvDtmfDigits.text = dtmfBuffer.toString()
                    LeadPilotCallManager.playDtmf(k[0])
                }
            }
            val params = GridLayout.LayoutParams().apply {
                width = 0
                height = GridLayout.LayoutParams.WRAP_CONTENT
                columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f)
            }
            dtmfGrid.addView(btn, params)
        }
    }

    private fun setupButtonListeners() {
        btnAnswer.setOnClickListener {
            InCallRingtoneManager.stopRinging(this)
            LeadPilotCallManager.answer()
        }
        btnDecline.setOnClickListener {
            InCallRingtoneManager.stopRinging(this)
            LeadPilotCallManager.rejectOrEnd()
        }
        btnEnd.setOnClickListener {
            InCallRingtoneManager.stopRinging(this)
            LeadPilotCallManager.rejectOrEnd()
        }

        btnMute.setOnClickListener { LeadPilotCallManager.toggleMute() }
        btnSpeaker.setOnClickListener { LeadPilotCallManager.toggleSpeaker() }
        btnAudio.setOnClickListener { LeadPilotCallManager.toggleBluetooth() }
        btnHold.setOnClickListener { LeadPilotCallManager.toggleHold() }

        btnKeypad.setOnClickListener {
            isKeypadVisible = !isKeypadVisible
            updateKeypadVisibility()
        }
        btnHideKeypad.setOnClickListener {
            isKeypadVisible = false
            updateKeypadVisibility()
        }

        btnOpenApp.setOnClickListener {
            openLeadPilotMain()
        }

        btnRecord.setOnClickListener {
            LeadPilotCallManager.toggleRecording(applicationContext)
            updateRecordButton()
        }

        btnSecondaryAction.setOnClickListener { LeadPilotCallManager.handleSecondaryAction() }
        btnSecondaryReject.setOnClickListener { LeadPilotCallManager.rejectSecondaryCall() }
    }

    private fun updateKeypadVisibility() {
        val call = LeadPilotCallManager.primaryCall
        val isRinging = call?.state == Call.STATE_RINGING
        if (isRinging) {
            controlsGrid.visibility = View.GONE
            dtmfPanel.visibility = View.GONE
        } else if (isKeypadVisible) {
            controlsGrid.visibility = View.GONE
            dtmfPanel.visibility = View.VISIBLE
        } else {
            controlsGrid.visibility = View.VISIBLE
            dtmfPanel.visibility = View.GONE
        }
    }

    override fun onNewIntent(intent: Intent?) {
        super.onNewIntent(intent)
        updateUi()
    }

    override fun onCallStateUpdated() {
        runOnUiThread {
            updateUi()
        }
    }

    private fun updateUi() {
        val call = LeadPilotCallManager.primaryCall
        if (call == null || call.state == Call.STATE_DISCONNECTED) {
            releaseProximityWakeLock()
            finish()
            return
        }

        val phone = LeadPilotCallManager.getPhoneNumber(call)
        val (displayName, student) = LeadPilotCallManager.resolveCallerDisplay(applicationContext, phone)

        tvName.text = displayName
        tvPhone.text = if (phone.isNotBlank() && phone != displayName) phone else "Mobile"
        tvAvatar.text = getInitials(displayName)

        if (student != null) {
            tvStatusBadge.visibility = View.VISIBLE
            tvStatusBadge.text = student.status.ifBlank { "Student Lead" }
            applyStatusStyle(tvStatusBadge, student.status)

            studentCard.visibility = View.VISIBLE
            val exam = listOf(student.examType, student.examYear).filter { it.isNotBlank() }.joinToString(" ")
            val meta = listOf(exam, student.location).filter { it.isNotBlank() }.joinToString(" • ")
            tvStudentMeta.text = meta.ifBlank { "Registered Student Lead" }

            if (student.streakCount >= 3) {
                tvStudentStreak.visibility = View.VISIBLE
                tvStudentStreak.text = "${student.streakCount}x No Answer"
            } else {
                tvStudentStreak.visibility = View.GONE
            }

            tvStudentComment.text = student.lastComment.ifBlank { "No previous comments recorded." }
        } else {
            tvStatusBadge.visibility = View.GONE
            studentCard.visibility = View.GONE
        }

        // Secondary Call (Call Waiting / Held)
        val sec = LeadPilotCallManager.secondaryCall
        if (sec != null && sec.state != Call.STATE_DISCONNECTED) {
            secondaryBanner.visibility = View.VISIBLE
            val secPhone = LeadPilotCallManager.getPhoneNumber(sec)
            val (secName, _) = LeadPilotCallManager.resolveCallerDisplay(applicationContext, secPhone)
            tvSecondaryName.text = secName
            if (sec.state == Call.STATE_RINGING) {
                tvSecondaryTitle.text = "Incoming Call Waiting"
                btnSecondaryAction.text = "Hold & Answer"
                btnSecondaryReject.text = "Decline"
            } else {
                tvSecondaryTitle.text = if (sec.state == Call.STATE_HOLDING) "On Hold" else "Active"
                btnSecondaryAction.text = "Swap"
                btnSecondaryReject.text = "End"
            }
        } else {
            secondaryBanner.visibility = View.GONE
        }

        // Ringing vs Active actions
        val isRinging = call.state == Call.STATE_RINGING
        incomingActions.visibility = if (isRinging) View.VISIBLE else View.GONE
        activeActions.visibility = if (isRinging) View.GONE else View.VISIBLE
        updateKeypadVisibility()

        // Audio & Hold button states
        val audioState = LeadPilotCallManager.currentAudioState
        val isMuted = audioState?.isMuted ?: false
        val route = audioState?.route ?: CallAudioState.ROUTE_EARPIECE
        val isSpeaker = route == CallAudioState.ROUTE_SPEAKER
        val isBluetooth = route == CallAudioState.ROUTE_BLUETOOTH
        val hasBluetooth = ((audioState?.supportedRouteMask ?: 0) and CallAudioState.ROUTE_BLUETOOTH) != 0
        val isHolding = call.state == Call.STATE_HOLDING

        btnMute.setBackgroundResource(if (isMuted) R.drawable.incall_btn_circle_active else R.drawable.incall_btn_circle)
        btnMute.setImageResource(if (isMuted) R.drawable.ic_incall_mic_off else R.drawable.ic_incall_mic)
        lblMute.text = if (isMuted) "Unmute" else "Mute"

        btnSpeaker.setBackgroundResource(if (isSpeaker) R.drawable.incall_btn_circle_active else R.drawable.incall_btn_circle)
        btnSpeaker.setColorFilter(if (isSpeaker) Color.parseColor("#0B131E") else Color.WHITE)
        lblSpeaker.text = if (isSpeaker) "Speaker On" else "Speaker"

        btnAudio.alpha = if (hasBluetooth) 1.0f else 0.4f
        btnAudio.isEnabled = hasBluetooth
        btnAudio.setBackgroundResource(if (isBluetooth) R.drawable.incall_btn_circle_active else R.drawable.incall_btn_circle)
        btnAudio.setColorFilter(if (isBluetooth) Color.parseColor("#0B131E") else Color.WHITE)
        lblAudio.text = if (isBluetooth) "BT Active" else "Bluetooth"

        val canHold = (call.state == Call.STATE_ACTIVE || call.state == Call.STATE_HOLDING) &&
            ((call.details?.callCapabilities ?: 0) and Call.Details.CAPABILITY_SUPPORT_HOLD != 0 ||
                (call.details?.callCapabilities ?: 0) and Call.Details.CAPABILITY_HOLD != 0)
        btnHold.isEnabled = canHold
        btnHold.alpha = if (canHold) 1.0f else 0.4f
        btnHold.setBackgroundResource(if (isHolding) R.drawable.incall_btn_circle_active else R.drawable.incall_btn_circle)
        btnHold.setColorFilter(if (isHolding) Color.parseColor("#0B131E") else Color.WHITE)
        lblHold.text = if (isHolding) "Resume" else "Hold"

        updateTimerText()
        updateProximitySensor(call.state, isSpeaker || isBluetooth)
        updateRecordButton()
    }

    private fun updateRecordButton() {
        val isRecording = CallRecorderManager.isRecording
        val isActive = LeadPilotCallManager.primaryCall?.state == Call.STATE_ACTIVE
        btnRecord.isEnabled = isActive
        btnRecord.alpha = if (isActive) 1.0f else 0.4f
        btnRecord.setBackgroundResource(if (isRecording) R.drawable.incall_btn_circle_active else R.drawable.incall_btn_circle)
        btnRecord.setImageResource(if (isRecording) R.drawable.ic_incall_mic else R.drawable.ic_incall_mic_off)
        btnRecord.setColorFilter(if (isRecording) Color.parseColor("#E53E3E") else Color.WHITE)
        lblRecord.text = if (isRecording) "Recording..." else "Record"
        lblRecord.setTextColor(if (isRecording) Color.parseColor("#FC8181") else Color.parseColor("#CBD5E1"))
    }

    private fun updateTimerText() {
        val call = LeadPilotCallManager.primaryCall ?: return
        when (call.state) {
            Call.STATE_RINGING -> {
                tvTimer.text = "Incoming call..."
                tvTimer.setTextColor(Color.parseColor("#6EE7B7"))
            }
            Call.STATE_DIALING, Call.STATE_CONNECTING -> {
                tvTimer.text = "Calling..."
                tvTimer.setTextColor(Color.parseColor("#94A3B8"))
            }
            Call.STATE_HOLDING -> {
                tvTimer.text = "On Hold"
                tvTimer.setTextColor(Color.parseColor("#FBBF24"))
            }
            Call.STATE_ACTIVE -> {
                val start = LeadPilotCallManager.callConnectedAtMs
                if (start > 0L) {
                    val elapsedSec = ((System.currentTimeMillis() - start) / 1000L).coerceAtLeast(0L)
                    val mins = elapsedSec / 60L
                    val secs = elapsedSec % 60L
                    tvTimer.text = String.format("%02d:%02d", mins, secs)
                } else {
                    tvTimer.text = "00:00"
                }
                tvTimer.setTextColor(Color.parseColor("#48BE9A"))
            }
            Call.STATE_DISCONNECTING -> {
                tvTimer.text = "Ending..."
                tvTimer.setTextColor(Color.parseColor("#FCA5A5"))
            }
            else -> {
                tvTimer.text = ""
            }
        }
    }

    private fun updateProximitySensor(state: Int, isExternalAudio: Boolean) {
        val shouldUseProximity = (state == Call.STATE_DIALING || state == Call.STATE_CONNECTING || state == Call.STATE_ACTIVE) && !isExternalAudio
        if (shouldUseProximity) {
            acquireProximityWakeLock()
        } else {
            releaseProximityWakeLock()
        }
    }

    private fun acquireProximityWakeLock() {
        try {
            if (proximityWakeLock == null) {
                val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP &&
                    pm.isWakeLockLevelSupported(PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK)) {
                    proximityWakeLock = pm.newWakeLock(
                        PowerManager.PROXIMITY_SCREEN_OFF_WAKE_LOCK,
                        "LeadPilot:InCallProximity"
                    )
                }
            }
            if (proximityWakeLock?.isHeld == false) {
                proximityWakeLock?.acquire(60 * 60 * 1000L)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Proximity wakelock error", e)
        }
    }

    private fun releaseProximityWakeLock() {
        try {
            if (proximityWakeLock?.isHeld == true) {
                proximityWakeLock?.release(PowerManager.RELEASE_FLAG_WAIT_FOR_NO_PROXIMITY)
            }
        } catch (_: Exception) {
            try {
                if (proximityWakeLock?.isHeld == true) proximityWakeLock?.release()
            } catch (_: Exception) {}
        }
    }

    private fun openLeadPilotMain() {
        try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                startActivity(intent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to open LeadPilot", e)
        }
    }

    private fun getInitials(name: String): String {
        val parts = name.trim().split("\\s+".toRegex()).filter { it.isNotEmpty() }
        return when {
            parts.isEmpty() -> "LP"
            parts.size == 1 -> parts[0].take(2).uppercase()
            else -> "${parts[0].first()}${parts[1].first()}".uppercase()
        }
    }

    private fun applyStatusStyle(tvStatus: TextView, status: String) {
        val s = status.lowercase().trim()
        val bg = tvStatus.background as? GradientDrawable ?: return
        when {
            s.contains("interest") || s.contains("paid") || s.contains("register") || s.contains("done") -> {
                bg.setColor(Color.parseColor("#0F2C33"))
                bg.setStroke(2, Color.parseColor("#48BE9A"))
                tvStatus.setTextColor(Color.parseColor("#62D6B0"))
            }
            s.contains("follow") || s.contains("call back") || s.contains("callback") || s.contains("pending") -> {
                bg.setColor(Color.parseColor("#15243B"))
                bg.setStroke(2, Color.parseColor("#3B82F6"))
                tvStatus.setTextColor(Color.parseColor("#60A5FA"))
            }
            s.contains("no answer") || s.contains("line busy") || s.contains("not responding") || s.contains("call cut") -> {
                bg.setColor(Color.parseColor("#3D2916"))
                bg.setStroke(2, Color.parseColor("#E58A18"))
                tvStatus.setTextColor(Color.parseColor("#FFAA48"))
            }
            s.contains("not interested") || s.contains("inactive") || s.contains("not potential") || s.contains("dropped") -> {
                bg.setColor(Color.parseColor("#3D1A1A"))
                bg.setStroke(2, Color.parseColor("#E65151"))
                tvStatus.setTextColor(Color.parseColor("#FF7878"))
            }
            else -> {
                bg.setColor(Color.parseColor("#1E293B"))
                bg.setStroke(2, Color.parseColor("#475569"))
                tvStatus.setTextColor(Color.parseColor("#94A3B8"))
            }
        }
    }

    override fun onStart() {
        super.onStart()
        FloatingCallOverlayManager.dismiss(this)
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations && LeadPilotCallManager.primaryCall != null && !isFinishing) {
            FloatingCallOverlayManager.show(this)
        }
    }

    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent?): Boolean {
        if (keyCode == android.view.KeyEvent.KEYCODE_VOLUME_DOWN || keyCode == android.view.KeyEvent.KEYCODE_VOLUME_UP) {
            if (LeadPilotCallManager.primaryCall?.state == Call.STATE_RINGING) {
                InCallRingtoneManager.stopRinging(this)
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onDestroy() {
        InCallRingtoneManager.stopRinging(this)
        handler.removeCallbacks(timerTick)
        LeadPilotCallManager.removeListener(this)
        releaseProximityWakeLock()
        if (LeadPilotCallManager.primaryCall == null) {
            FloatingCallOverlayManager.dismiss(this)
        }
        super.onDestroy()
    }
}
