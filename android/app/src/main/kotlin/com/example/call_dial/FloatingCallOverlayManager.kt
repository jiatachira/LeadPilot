package com.example.call_dial

import android.content.Context
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.telecom.Call
import android.telecom.CallAudioState
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView

object FloatingCallOverlayManager : CallStateListener {
    private const val TAG = "FloatingCallOverlay"

    private var overlayView: View? = null
    private var appContext: Context? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    private var lastX: Int? = null
    private var lastY: Int? = null

    private val timerRunnable = object : Runnable {
        override fun run() {
            updateTimer()
            mainHandler.postDelayed(this, 1000L)
        }
    }

    fun show(context: Context) {
        mainHandler.post {
            try {
                val app = context.applicationContext ?: context
                appContext = app

                if (!Settings.canDrawOverlays(app)) {
                    Log.d(TAG, "SYSTEM_ALERT_WINDOW permission not granted. Cannot show floating call pill.")
                    return@post
                }

                if (LeadPilotCallManager.primaryCall == null) {
                    dismissInternal()
                    return@post
                }

                if (overlayView != null) {
                    updateUi()
                    return@post
                }

                val windowManager = app.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
                    ?: return@post

                val inflater = LayoutInflater.from(app)
                val view = inflater.inflate(R.layout.floating_call_overlay, null)
                overlayView = view

                val layoutFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_PHONE
                }

                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    layoutFlag,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN or
                        WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
                    PixelFormat.TRANSLUCENT
                ).apply {
                    gravity = Gravity.TOP or Gravity.START
                    val metrics = app.resources.displayMetrics
                    x = lastX ?: (metrics.widthPixels - (260 * metrics.density).toInt()).coerceAtLeast(20)
                    y = lastY ?: (120 * metrics.density).toInt()
                }

                // Bind touch drag listener on view
                var initialX = 0
                var initialY = 0
                var initialTouchX = 0f
                var initialTouchY = 0f
                var isDragging = false

                view.setOnTouchListener { _, event ->
                    when (event.action) {
                        MotionEvent.ACTION_DOWN -> {
                            initialX = params.x
                            initialY = params.y
                            initialTouchX = event.rawX
                            initialTouchY = event.rawY
                            isDragging = false
                            true
                        }
                        MotionEvent.ACTION_MOVE -> {
                            val dx = event.rawX - initialTouchX
                            val dy = event.rawY - initialTouchY
                            if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
                                isDragging = true
                            }
                            if (isDragging) {
                                params.x = (initialX + dx).toInt()
                                params.y = (initialY + dy).toInt()
                                lastX = params.x
                                lastY = params.y
                                try {
                                    windowManager.updateViewLayout(view, params)
                                } catch (_: Exception) {}
                            }
                            true
                        }
                        MotionEvent.ACTION_UP -> {
                            if (!isDragging) {
                                // Tap on pill body -> Maximize InCallActivity
                                InCallActivity.start(app)
                                dismiss(app)
                            }
                            true
                        }
                        else -> false
                    }
                }

                // Buttons
                val btnAudio = view.findViewById<ImageButton>(R.id.floating_btn_audio)
                val btnEnd = view.findViewById<ImageButton>(R.id.floating_btn_end)

                btnAudio.setOnClickListener {
                    LeadPilotCallManager.cycleAudioRoute()
                    updateUi()
                }

                btnEnd.setOnClickListener {
                    LeadPilotCallManager.rejectOrEnd()
                    dismiss(app)
                }

                windowManager.addView(view, params)
                LeadPilotCallManager.addListener(this)

                mainHandler.removeCallbacks(timerRunnable)
                mainHandler.post(timerRunnable)

                updateUi()
                Log.d(TAG, "Floating call pill displayed successfully")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to show floating call pill", e)
            }
        }
    }

    fun dismiss(context: Context? = null) {
        mainHandler.post {
            dismissInternal()
        }
    }

    private fun dismissInternal() {
        try {
            LeadPilotCallManager.removeListener(this)
            mainHandler.removeCallbacks(timerRunnable)

            val view = overlayView ?: return
            val ctx = appContext ?: return
            val windowManager = ctx.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            if (windowManager != null) {
                if (view.isAttachedToWindow) {
                    windowManager.removeView(view)
                } else {
                    windowManager.removeViewImmediate(view)
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error dismissing floating call pill", e)
        } finally {
            overlayView = null
        }
    }

    override fun onCallStateUpdated() {
        mainHandler.post {
            if (LeadPilotCallManager.primaryCall == null) {
                dismissInternal()
            } else {
                updateUi()
            }
        }
    }

    private fun updateUi() {
        val view = overlayView ?: return
        val ctx = appContext ?: return
        val call = LeadPilotCallManager.primaryCall

        if (call == null) {
            dismissInternal()
            return
        }

        val phone = LeadPilotCallManager.getPhoneNumber(call)
        val (displayName, _) = LeadPilotCallManager.resolveCallerDisplay(ctx, phone)

        val tvName = view.findViewById<TextView>(R.id.floating_caller_name)
        val tvStatus = view.findViewById<TextView>(R.id.floating_call_status)
        val dotStatus = view.findViewById<View>(R.id.floating_status_dot)
        val btnAudio = view.findViewById<ImageButton>(R.id.floating_btn_audio)

        tvName.text = displayName.ifEmpty { phone.ifEmpty { "Active Call" } }

        val dotBg = dotStatus.background as? GradientDrawable

        when (call.state) {
            Call.STATE_RINGING -> {
                tvStatus.text = "Ringing..."
                tvStatus.setTextColor(Color.parseColor("#F59E0B"))
                dotBg?.setColor(Color.parseColor("#F59E0B"))
            }
            Call.STATE_DIALING, Call.STATE_CONNECTING -> {
                tvStatus.text = "Calling..."
                tvStatus.setTextColor(Color.parseColor("#60A5FA"))
                dotBg?.setColor(Color.parseColor("#3B82F6"))
            }
            Call.STATE_HOLDING -> {
                tvStatus.text = "On Hold"
                tvStatus.setTextColor(Color.parseColor("#F59E0B"))
                dotBg?.setColor(Color.parseColor("#F59E0B"))
            }
            Call.STATE_ACTIVE -> {
                updateTimer()
                tvStatus.setTextColor(Color.parseColor("#4ADE80"))
                dotBg?.setColor(Color.parseColor("#22C55E"))
            }
            Call.STATE_DISCONNECTED, Call.STATE_DISCONNECTING -> {
                tvStatus.text = "Ended"
                tvStatus.setTextColor(Color.parseColor("#EF4444"))
                dotBg?.setColor(Color.parseColor("#EF4444"))
                mainHandler.postDelayed({ dismissInternal() }, 800L)
            }
            else -> {
                tvStatus.text = "Connecting..."
                tvStatus.setTextColor(Color.parseColor("#94A3B8"))
                dotBg?.setColor(Color.parseColor("#94A3B8"))
            }
        }

        // Update audio button icon based on current route
        val audioState = LeadPilotCallManager.currentAudioState
        val route = audioState?.route ?: CallAudioState.ROUTE_EARPIECE
        when (route) {
            CallAudioState.ROUTE_SPEAKER -> {
                btnAudio.setImageResource(R.drawable.ic_incall_speaker)
                btnAudio.setBackgroundResource(R.drawable.incall_btn_circle_active)
            }
            CallAudioState.ROUTE_BLUETOOTH -> {
                btnAudio.setImageResource(R.drawable.ic_incall_bluetooth)
                btnAudio.setBackgroundResource(R.drawable.incall_btn_circle_active)
            }
            else -> {
                btnAudio.setImageResource(R.drawable.ic_incall_call)
                btnAudio.setBackgroundResource(R.drawable.incall_btn_circle)
            }
        }
    }

    private fun updateTimer() {
        val view = overlayView ?: return
        val call = LeadPilotCallManager.primaryCall ?: return
        if (call.state != Call.STATE_ACTIVE) return

        val connectTime = LeadPilotCallManager.callConnectedAtMs
        val elapsedSec = if (connectTime > 0L) {
            ((System.currentTimeMillis() - connectTime) / 1000L).coerceAtLeast(0L)
        } else {
            0L
        }

        val mm = elapsedSec / 60
        val ss = elapsedSec % 60
        val formatted = String.format("%02d:%02d", mm, ss)

        val tvStatus = view.findViewById<TextView>(R.id.floating_call_status)
        tvStatus.text = formatted
    }
}
