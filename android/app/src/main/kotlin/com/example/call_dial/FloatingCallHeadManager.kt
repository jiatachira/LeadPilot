package com.example.call_dial

import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.telecom.TelecomManager
import android.telephony.TelephonyManager
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.ImageButton
import android.widget.TextView
import androidx.core.content.ContextCompat

object FloatingCallHeadManager {
    private const val TAG = "FloatingCallHeadMgr"
    private var overlayView: View? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    fun show(context: Context, name: String, phone: String) {
        mainHandler.post {
            try {
                val appContext = context.applicationContext ?: context
                if (!Settings.canDrawOverlays(appContext)) {
                    Log.w(TAG, "SYSTEM_ALERT_WINDOW permission not granted. Cannot display floating call head.")
                    return@post
                }

                val windowManager = appContext.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
                    ?: return@post

                // Dismiss existing if any
                dismissInternal(windowManager)

                val inflater = LayoutInflater.from(appContext)
                val view = inflater.inflate(R.layout.floating_call_head, null)
                overlayView = view

                val tvName = view.findViewById<TextView>(R.id.call_head_name)
                val btnEnd = view.findViewById<ImageButton>(R.id.call_head_btn_end)

                tvName.text = name.ifBlank { "Student Call" }

                // End Call button action
                btnEnd.setOnClickListener {
                    Log.d(TAG, "End Call button tapped on floating head.")
                    endActiveCall(appContext)
                    dismiss(appContext)
                }

                // Window Layout Params
                val layoutFlag = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
                } else {
                    @Suppress("DEPRECATION")
                    WindowManager.LayoutParams.TYPE_PHONE
                }

                val density = appContext.resources.displayMetrics.density
                val initialX = (16 * density).toInt()
                val initialY = (120 * density).toInt()

                var windowFlags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON

                @Suppress("DEPRECATION")
                windowFlags = windowFlags or WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED

                val params = WindowManager.LayoutParams(
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    WindowManager.LayoutParams.WRAP_CONTENT,
                    layoutFlag,
                    windowFlags,
                    PixelFormat.TRANSLUCENT
                )
                params.gravity = Gravity.TOP or Gravity.START
                params.x = initialX
                params.y = initialY

                // Touch listener for smooth dragging and tap to open app
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
                                    Log.e(TAG, "Failed to update floating call head position", e)
                                }
                            }
                            true
                        }
                        MotionEvent.ACTION_UP -> {
                            if (!isDragging) {
                                val dx = Math.abs(event.rawX - initialTouchX)
                                val dy = Math.abs(event.rawY - initialTouchY)
                                if (dx < 10 && dy < 10) {
                                    openApp(appContext)
                                }
                            }
                            true
                        }
                        else -> false
                    }
                }

                windowManager.addView(view, params)
                Log.d(TAG, "Floating call head displayed for $name")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to show floating call head", e)
            }
        }
    }

    fun isShowing(): Boolean = overlayView != null

    fun dismiss(context: Context) {
        mainHandler.post {
            try {
                val appContext = context.applicationContext ?: context
                val windowManager = appContext.getSystemService(Context.WINDOW_SERVICE) as? WindowManager
                dismissInternal(windowManager)
            } catch (e: Exception) {
                Log.e(TAG, "Error dismissing floating call head", e)
            }
        }
    }

    private fun dismissInternal(windowManager: WindowManager?) {
        try {
            overlayView?.let { v ->
                windowManager?.removeView(v)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error removing overlayView from WindowManager", e)
        } finally {
            overlayView = null
        }
    }

    fun endActiveCall(context: Context): Boolean {
        var ended = false
        val appContext = context.applicationContext ?: context

        // 1. Android 9 (API 28) and newer: TelecomManager.endCall()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                val telecomManager = appContext.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                if (telecomManager != null &&
                    ContextCompat.checkSelfPermission(appContext, android.Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED) {
                    ended = telecomManager.endCall()
                    Log.d(TAG, "TelecomManager.endCall() invoked, result=$ended")
                }
            } catch (e: Exception) {
                Log.w(TAG, "TelecomManager.endCall() failed: ${e.message}")
            }
        }

        // 2. Fallback via reflection on TelecomManager
        if (!ended) {
            try {
                val telecomManager = appContext.getSystemService(Context.TELECOM_SERVICE) as? TelecomManager
                if (telecomManager != null) {
                    val endCallMethod = telecomManager.javaClass.getDeclaredMethod("endCall")
                    endCallMethod.isAccessible = true
                    val res = endCallMethod.invoke(telecomManager)
                    if (res is Boolean) ended = res
                    Log.d(TAG, "TelecomManager reflection endCall invoked, result=$ended")
                }
            } catch (e: Exception) {
                Log.w(TAG, "TelecomManager reflection endCall failed: ${e.message}")
            }
        }

        // 3. Fallback via reflection on TelephonyManager (ITelephony)
        if (!ended) {
            try {
                val telephonyManager = appContext.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
                if (telephonyManager != null) {
                    val getITelephony = telephonyManager.javaClass.getDeclaredMethod("getITelephony")
                    getITelephony.isAccessible = true
                    val iTelephony = getITelephony.invoke(telephonyManager)
                    val endCallMethod = iTelephony.javaClass.getDeclaredMethod("endCall")
                    endCallMethod.isAccessible = true
                    endCallMethod.invoke(iTelephony)
                    ended = true
                    Log.d(TAG, "ITelephony reflection endCall invoked successfully")
                }
            } catch (e: Exception) {
                Log.w(TAG, "ITelephony reflection endCall failed: ${e.message}")
            }
        }

        return ended
    }

    private fun openApp(context: Context) {
        try {
            val intent = context.packageManager.getLaunchIntentForPackage(context.packageName)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT)
            }
            if (intent != null) {
                context.startActivity(intent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to launch main app from floating call head", e)
        }
    }
}
