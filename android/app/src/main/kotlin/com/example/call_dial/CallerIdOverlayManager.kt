package com.example.call_dial

import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView

object CallerIdOverlayManager {
    private const val TAG = "CallerIdOverlayManager"
    private var overlayView: View? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun show(context: Context, info: StudentCallerInfo) {
        mainHandler.post {
            try {
                val appContext = context.applicationContext ?: context
                if (!Settings.canDrawOverlays(appContext)) {
                    Log.w(TAG, "SYSTEM_ALERT_WINDOW permission not granted. Cannot display overlay.")
                    return@post
                }

                val windowManager = appContext.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
                    ?: return@post

                // Dismiss any existing overlay first
                dismissInternal(windowManager)

                val inflater = LayoutInflater.from(appContext)
                val view = inflater.inflate(R.layout.caller_id_overlay, null)
                overlayView = view

                // Populate views
                val tvAvatar = view.findViewById<TextView>(R.id.caller_id_avatar)
                val tvName = view.findViewById<TextView>(R.id.caller_id_name)
                val tvPhone = view.findViewById<TextView>(R.id.caller_id_phone)
                val tvStatus = view.findViewById<TextView>(R.id.caller_id_status)
                val tvMeta = view.findViewById<TextView>(R.id.caller_id_meta)
                val tvStreak = view.findViewById<TextView>(R.id.caller_id_streak)
                val tvComment = view.findViewById<TextView>(R.id.caller_id_comment)
                val btnClose = view.findViewById<ImageButton>(R.id.caller_id_btn_close)
                val btnOpen = view.findViewById<LinearLayout>(R.id.caller_id_btn_open)

                // Name & Phone
                tvName.text = info.name
                tvPhone.text = info.phone.ifEmpty { "Registered Lead" }

                // Avatar initials
                val initials = getInitials(info.name)
                tvAvatar.text = initials

                // Status & Styling
                tvStatus.text = info.status.ifEmpty { "Pending" }
                applyStatusStyle(tvStatus, info.status)

                // Meta (Exam / Year / Location)
                val metaParts = mutableListOf<String>()
                val exam = listOf(info.examType, info.examYear).filter { it.isNotBlank() }.joinToString(" ")
                if (exam.isNotBlank()) metaParts.add(exam)
                if (info.location.isNotBlank()) metaParts.add(info.location)
                tvMeta.text = if (metaParts.isNotEmpty()) metaParts.joinToString(" • ") else "Student Lead"

                // Unanswered streak
                if (info.streakCount >= 3) {
                    tvStreak.visibility = View.VISIBLE
                    if (info.streakCount >= 5) {
                        tvStreak.text = "🚨 ${info.streakCount}x No Answer"
                        val bg = tvStreak.background as? GradientDrawable
                        bg?.setColor(Color.parseColor("#3D1A1A"))
                        bg?.setStroke(2, Color.parseColor("#E65151"))
                        tvStreak.setTextColor(Color.parseColor("#FF7878"))
                    } else {
                        tvStreak.text = "⚠️ ${info.streakCount}x No Answer"
                        val bg = tvStreak.background as? GradientDrawable
                        bg?.setColor(Color.parseColor("#3D2916"))
                        bg?.setStroke(2, Color.parseColor("#E58A18"))
                        tvStreak.setTextColor(Color.parseColor("#FFAA48"))
                    }
                } else {
                    tvStreak.visibility = View.GONE
                }

                // Last comment
                if (info.lastComment.isNotBlank()) {
                    tvComment.text = info.lastComment
                } else {
                    tvComment.text = "No previous comments recorded."
                }

                // Window layout params
                val layoutFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_PHONE
                }

                val density = context.resources.displayMetrics.density
                val initialY = (100 * density).toInt()

                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.MATCH_PARENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    layoutFlag,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                        WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON,
                    PixelFormat.TRANSLUCENT
                )
                params.gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                params.y = initialY

                // Close button action
                btnClose.setOnClickListener {
                    dismiss(context)
                }

                // Open App action
                btnOpen.setOnClickListener {
                    openApp(context, info.phone)
                    dismiss(context)
                }

                // Touch listener for smooth dragging
                var initialParamX = 0
                var initialParamY = 0
                var initialTouchX = 0f
                var initialTouchY = 0f
                var isDragging = false

                view.setOnTouchListener { _, event ->
                    when (event.action) {
                        MotionEvent.ACTION_DOWN -> {
                            initialParamX = params.x
                            initialParamY = params.y
                            initialTouchX = event.rawX
                            initialTouchY = event.rawY
                            isDragging = false
                            true
                        }
                        MotionEvent.ACTION_MOVE -> {
                            val dx = (event.rawX - initialTouchX).toInt()
                            val dy = (event.rawY - initialTouchY).toInt()
                            if (Math.abs(dx) > 10 || Math.abs(dy) > 10) {
                                isDragging = true
                                params.x = initialParamX + dx
                                params.y = initialParamY + dy
                                try {
                                    windowManager.updateViewLayout(view, params)
                                } catch (e: Exception) {
                                    Log.e(TAG, "Failed to update overlay position", e)
                                }
                            }
                            true
                        }
                        MotionEvent.ACTION_UP -> {
                            // If just a tap on empty area without drag, we could trigger open app
                            if (!isDragging) {
                                val dx = Math.abs(event.rawX - initialTouchX)
                                val dy = Math.abs(event.rawY - initialTouchY)
                                if (dx < 10 && dy < 10) {
                                    openApp(context, info.phone)
                                    dismiss(context)
                                }
                            }
                            true
                        }
                        else -> false
                    }
                }

                windowManager.addView(view, params)
                Log.d(TAG, "Caller ID overlay successfully displayed for ${info.name}")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to show caller ID overlay", e)
            }
        }
    }

    fun dismiss(context: Context) {
        mainHandler.post {
            try {
                val appContext = context.applicationContext ?: context
                val windowManager = appContext.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
                    ?: return@post
                dismissInternal(windowManager)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to dismiss overlay", e)
            }
        }
    }

    private fun dismissInternal(windowManager: WindowManager) {
        overlayView?.let { view ->
            try {
                windowManager.removeView(view)
            } catch (e: Exception) {
                Log.e(TAG, "Error removing overlay view", e)
            }
        }
        overlayView = null
    }

    private fun getInitials(name: String): String {
        val parts = name.trim().split("\\s+".toRegex()).filter { it.isNotEmpty() }
        return when {
            parts.isEmpty() -> "ST"
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

    private fun openApp(context: Context, phone: String) {
        try {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)
            if (intent != null) {
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                intent.putExtra("from_caller_id", true)
                intent.putExtra("student_phone", phone)
                context.startActivity(intent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch app from overlay", e)
        }
    }
}
