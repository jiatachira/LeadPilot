package com.example.call_dial

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.TextView

class CallerIdActivity : Activity() {
    companion object {
        private const val TAG = "CallerIdActivity"
        private var currentActivity: CallerIdActivity? = null

        fun start(context: Context, info: StudentCallerInfo) {
            try {
                val intent = Intent(context, CallerIdActivity::class.java).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                    addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                    putExtra("name", info.name)
                    putExtra("phone", info.phone)
                    putExtra("status", info.status)
                    putExtra("location", info.location)
                    putExtra("examType", info.examType)
                    putExtra("examYear", info.examYear)
                    putExtra("lastComment", info.lastComment)
                    putExtra("streakCount", info.streakCount)
                }
                context.startActivity(intent)
                Log.d(TAG, "CallerIdActivity successfully started for ${info.name}")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start CallerIdActivity", e)
            }
        }

        fun dismissCurrent() {
            try {
                currentActivity?.finish()
            } catch (e: Exception) {
                Log.e(TAG, "Failed to finish current CallerIdActivity", e)
            }
            currentActivity = null
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        currentActivity = this

        setupLockScreenFlags()
        setContentView(R.layout.caller_id_activity)

        // Cancel the notification banner so there is NO duplicate heads-up popup over the activity
        CallerIdNotificationHelper.cancel(this)

        val name = intent.getStringExtra("name") ?: "Student Lead"
        val phone = intent.getStringExtra("phone") ?: ""
        val status = intent.getStringExtra("status") ?: "Pending"
        val location = intent.getStringExtra("location") ?: ""
        val examType = intent.getStringExtra("examType") ?: ""
        val examYear = intent.getStringExtra("examYear") ?: ""
        val lastComment = intent.getStringExtra("lastComment") ?: ""
        val streakCount = intent.getIntExtra("streakCount", 0)

        bindViews(name, phone, status, location, examType, examYear, lastComment, streakCount)
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
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }

        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }

    private fun bindViews(
        name: String,
        phone: String,
        status: String,
        location: String,
        examType: String,
        examYear: String,
        lastComment: String,
        streakCount: Int
    ) {
        val tvAvatar = findViewById<TextView>(R.id.caller_id_avatar)
        val tvName = findViewById<TextView>(R.id.caller_id_name)
        val tvPhone = findViewById<TextView>(R.id.caller_id_phone)
        val tvStatus = findViewById<TextView>(R.id.caller_id_status)
        val tvMeta = findViewById<TextView>(R.id.caller_id_meta)
        val tvStreak = findViewById<TextView>(R.id.caller_id_streak)
        val tvComment = findViewById<TextView>(R.id.caller_id_comment)
        val btnClose = findViewById<ImageButton>(R.id.caller_id_btn_close)
        val btnOpen = findViewById<LinearLayout>(R.id.caller_id_btn_open)
        val container = findViewById<View>(R.id.caller_id_activity_container)

        tvName.text = name
        tvPhone.text = phone.ifEmpty { "Registered Lead" }
        tvAvatar.text = getInitials(name)
        tvStatus.text = status.ifEmpty { "Pending" }
        applyStatusStyle(tvStatus, status)

        val metaParts = mutableListOf<String>()
        val exam = listOf(examType, examYear).filter { it.isNotBlank() }.joinToString(" ")
        if (exam.isNotBlank()) metaParts.add(exam)
        if (location.isNotBlank()) metaParts.add(location)
        tvMeta.text = if (metaParts.isNotEmpty()) metaParts.joinToString(" • ") else "Student Lead"

        if (streakCount >= 3) {
            tvStreak.visibility = View.VISIBLE
            if (streakCount >= 5) {
                tvStreak.text = "🚨 ${streakCount}x No Answer"
                val bg = tvStreak.background as? GradientDrawable
                bg?.setColor(Color.parseColor("#3D1A1A"))
                bg?.setStroke(2, Color.parseColor("#E65151"))
                tvStreak.setTextColor(Color.parseColor("#FF7878"))
            } else {
                tvStreak.text = "⚠️ ${streakCount}x No Answer"
                val bg = tvStreak.background as? GradientDrawable
                bg?.setColor(Color.parseColor("#3D2916"))
                bg?.setStroke(2, Color.parseColor("#E58A18"))
                tvStreak.setTextColor(Color.parseColor("#FFAA48"))
            }
        } else {
            tvStreak.visibility = View.GONE
        }

        tvComment.text = if (lastComment.isNotBlank()) lastComment else "No previous comments recorded."

        btnClose.setOnClickListener {
            finish()
        }

        btnOpen.setOnClickListener {
            openLeadPilot(phone)
            finish()
        }

        // Tap on the backdrop dismisses the dialog
        container.setOnClickListener {
            finish()
        }
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

    private fun openLeadPilot(phone: String) {
        try {
            val intent = packageManager.getLaunchIntentForPackage(packageName)
            if (intent != null) {
                intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED
                intent.putExtra("from_caller_id", true)
                intent.putExtra("student_phone", phone)
                startActivity(intent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch main app", e)
        }
    }

    override fun onDestroy() {
        if (currentActivity == this) {
            currentActivity = null
        }
        super.onDestroy()
    }
}
