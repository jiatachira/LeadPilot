package com.example.call_dial

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.net.Uri
import android.os.Build
import android.provider.CallLog
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterFragmentActivity() {
    private val ringtoneChannelName = "com.example.call_dial/ringtone"
    private val callerIdChannelName = "com.example.call_dial/caller_id"
    private val speechChannelName = "com.example.call_dial/speech"
    private var ringtone: Ringtone? = null

    private var pendingPhonePermissionResult: MethodChannel.Result? = null
    private val phonePermissionRequestCode = 2001
    private var pendingSpeechResult: MethodChannel.Result? = null
    private val speechRecognitionRequestCode = 3001

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Ringtone Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ringtoneChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "playRingtone" -> {
                        try {
                            stopCurrentRingtone()
                            val uri: Uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
                                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
                            val r = RingtoneManager.getRingtone(applicationContext, uri)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                r?.isLooping = true
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                                r?.audioAttributes = AudioAttributes.Builder()
                                    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                                    .build()
                            } else {
                                @Suppress("DEPRECATION")
                                r?.streamType = AudioManager.STREAM_RING
                            }
                            r?.play()
                            ringtone = r
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("RINGTONE_ERROR", e.message, null)
                        }
                    }
                    "stopRingtone" -> {
                        try {
                            stopCurrentRingtone()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("RINGTONE_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Caller ID Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, callerIdChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "syncCallerIdData" -> {
                        try {
                            val students = call.argument<List<Map<String, Any>>>("students") ?: emptyList()
                            CallerIdCacheManager.saveStudents(applicationContext, students)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SYNC_ERROR", e.message, null)
                        }
                    }
                    "isCallerIdEnabled" -> {
                        result.success(CallerIdCacheManager.isCallerIdEnabled(applicationContext))
                    }
                    "setCallerIdEnabled" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        CallerIdCacheManager.setCallerIdEnabled(applicationContext, enabled)
                        result.success(true)
                    }
                    "canDrawOverlays" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }
                    "requestOverlayPermission" -> {
                        try {
                            val intent = Intent(
                                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                                Uri.parse("package:$packageName")
                            )
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("OVERLAY_ERROR", e.message, null)
                        }
                    }
                    "hasPhonePermissions" -> {
                        result.success(checkHasPhonePermissions())
                    }
                    "requestPhonePermissions" -> {
                        if (checkHasPhonePermissions()) {
                            result.success(true)
                        } else {
                            val permissions = mutableListOf(Manifest.permission.READ_PHONE_STATE)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                                permissions.add(Manifest.permission.READ_CALL_LOG)
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                permissions.add(Manifest.permission.READ_PHONE_NUMBERS)
                            }
                            pendingPhonePermissionResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                permissions.toTypedArray(),
                                phonePermissionRequestCode
                            )
                        }
                    }
                    "getCachedStudentCount" -> {
                        result.success(CallerIdCacheManager.getCachedStudentCount(applicationContext))
                    }
                    "testCallerIdPopup" -> {
                        try {
                            val sampleInfo = StudentCallerInfo(
                                name = "Kamal Perera",
                                phone = "077 123 4567",
                                status = "Interested",
                                location = "Colombo",
                                examType = "2026 A/L",
                                examYear = "",
                                lastComment = "Asked to call back tomorrow afternoon after 4 PM.",
                                streakCount = 3
                            )
                            CallerIdOverlayManager.show(applicationContext, sampleInfo)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("TEST_POPUP_ERROR", e.message, null)
                        }
                    }
                    "dismissOverlay" -> {
                        CallerIdNotificationHelper.cancel(applicationContext)
                        CallerIdActivity.dismissCurrent()
                        CallerIdOverlayManager.dismiss(applicationContext)
                        result.success(true)
                    }
                    "testNotificationBanner" -> {
                        try {
                            val sampleInfo = StudentCallerInfo(
                                name = "Kamal Perera",
                                phone = "077 123 4567",
                                status = "Interested",
                                location = "Colombo",
                                examType = "2026 A/L",
                                examYear = "",
                                lastComment = "Asked to call back tomorrow afternoon after 4 PM.",
                                streakCount = 3
                            )
                            CallerIdNotificationHelper.show(applicationContext, sampleInfo)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("TEST_NOTIFICATION_ERROR", e.message, null)
                        }
                    }
                    "isIgnoringBatteryOptimizations" -> {
                        val powerManager = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
                        val isIgnoring = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            powerManager?.isIgnoringBatteryOptimizations(packageName) ?: true
                        } else {
                            true
                        }
                        result.success(isIgnoring)
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                                val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                    data = Uri.parse("package:$packageName")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                result.success(true)
                            } else {
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            try {
                                val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(fallback)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("BATTERY_ERROR", e2.message, null)
                            }
                        }
                    }
                    "openAppDetailsSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    }
                    "getLatestCallLog" -> {
                        try {
                            val phone = call.argument<String>("phone")
                            val log = getLatestCallLogForPhone(phone)
                            result.success(log)
                        } catch (e: Exception) {
                            result.error("CALL_LOG_ERROR", e.message, null)
                        }
                    }
                    "getPendingCallLogs" -> {
                        try {
                            val list = CallerIdCacheManager.getPendingCallLogs(applicationContext).map { obj ->
                                mapOf(
                                    "phone" to obj.optString("phone"),
                                    "duration" to obj.optLong("duration"),
                                    "type" to obj.optString("type"),
                                    "timestamp" to obj.optLong("timestamp")
                                )
                            }
                            CallerIdCacheManager.clearPendingCallLogs(applicationContext)
                            result.success(list)
                        } catch (e: Exception) {
                            result.error("PENDING_LOGS_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // App Installer Channel
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.example.call_dial/installer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getApkDownloadPath" -> {
                        try {
                            val dir = File(cacheDir, "updates")
                            if (!dir.exists()) dir.mkdirs()
                            val file = File(dir, "LeadPilot-update.apk")
                            result.success(file.absolutePath)
                        } catch (e: Exception) {
                            result.error("PATH_ERROR", e.message, null)
                        }
                    }
                    "canRequestPackageInstalls" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            result.success(packageManager.canRequestPackageInstalls())
                        } else {
                            result.success(true)
                        }
                    }
                    "openInstallPermissionSettings" -> {
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                    data = Uri.parse("package:$packageName")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                result.success(true)
                            } else {
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", e.message, null)
                        }
                    }
                    "installApk" -> {
                        try {
                            val filePath = call.argument<String>("filePath")
                            if (filePath.isNullOrEmpty()) {
                                result.error("INVALID_PATH", "APK path is empty", null)
                                return@setMethodCallHandler
                            }
                            val file = File(filePath)
                            if (!file.exists()) {
                                result.error("FILE_NOT_FOUND", "APK file does not exist", null)
                                return@setMethodCallHandler
                            }

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                                val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                                    data = Uri.parse("package:$packageName")
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                startActivity(intent)
                                result.error("PERMISSION_REQUIRED", "Please allow LeadPilot to install unknown apps.", null)
                                return@setMethodCallHandler
                            }

                            val uri = androidx.core.content.FileProvider.getUriForFile(
                                applicationContext,
                                "$packageName.fileprovider",
                                file
                            )
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/vnd.android.package-archive")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("INSTALL_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Speech Recognition Channel (Native Google Speech Dialog)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, speechChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isRecognitionAvailable" -> {
                        try {
                            val intent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
                            val activities = packageManager.queryIntentActivities(intent, 0)
                            result.success(activities.isNotEmpty())
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "recognizeSpeech" -> {
                        try {
                            val prompt = call.argument<String>("prompt") ?: "Speak your call remark..."
                            val intent = Intent(android.speech.RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                                putExtra(
                                    android.speech.RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                                    android.speech.RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
                                )
                                putExtra(android.speech.RecognizerIntent.EXTRA_PROMPT, prompt)
                                putExtra(android.speech.RecognizerIntent.EXTRA_MAX_RESULTS, 3)
                            }
                            pendingSpeechResult = result
                            startActivityForResult(intent, speechRecognitionRequestCode)
                        } catch (e: Exception) {
                            pendingSpeechResult = null
                            result.error("SPEECH_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == speechRecognitionRequestCode) {
            if (resultCode == RESULT_OK && data != null) {
                val results = data.getStringArrayListExtra(android.speech.RecognizerIntent.EXTRA_RESULTS)
                val spokenText = results?.firstOrNull() ?: ""
                pendingSpeechResult?.success(spokenText)
            } else {
                pendingSpeechResult?.success("")
            }
            pendingSpeechResult = null
        }
    }

    private fun checkHasPhonePermissions(): Boolean {
        val phoneStateOk = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.READ_PHONE_STATE
        ) == PackageManager.PERMISSION_GRANTED

        val callLogOk = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            ContextCompat.checkSelfPermission(
                this,
                Manifest.permission.READ_CALL_LOG
            ) == PackageManager.PERMISSION_GRANTED
        } else {
            true
        }

        return phoneStateOk && callLogOk
    }

    private fun getLatestCallLogForPhone(targetPhone: String?): Map<String, Any>? {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) {
            android.util.Log.w("MainActivity", "READ_CALL_LOG permission not granted when fetching call duration")
            return null
        }
        val cr = contentResolver ?: return null
        val normTarget = CallerIdCacheManager.normalizePhoneNumber(targetPhone)

        val cursor = cr.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(
                CallLog.Calls.NUMBER,
                CallLog.Calls.DURATION,
                CallLog.Calls.TYPE,
                CallLog.Calls.DATE
            ),
            null,
            null,
            "${CallLog.Calls.DATE} DESC"
        ) ?: return null

        cursor.use { c ->
            val numIdx = c.getColumnIndex(CallLog.Calls.NUMBER)
            val durIdx = c.getColumnIndex(CallLog.Calls.DURATION)
            val typeIdx = c.getColumnIndex(CallLog.Calls.TYPE)
            val dateIdx = c.getColumnIndex(CallLog.Calls.DATE)

            var checkedCount = 0
            while (c.moveToNext() && checkedCount < 10) {
                checkedCount++
                val number = if (numIdx >= 0) c.getString(numIdx) ?: "" else ""
                val duration = if (durIdx >= 0) c.getLong(durIdx) else 0L
                val type = if (typeIdx >= 0) c.getInt(typeIdx) else 0
                val date = if (dateIdx >= 0) c.getLong(dateIdx) else 0L

                val normNum = CallerIdCacheManager.normalizePhoneNumber(number)
                val isMatch = if (normTarget.isNotEmpty() && normNum.isNotEmpty()) {
                    normTarget == normNum || normNum.endsWith(normTarget) || normTarget.endsWith(normNum)
                } else if (normTarget.isEmpty()) {
                    true
                } else {
                    number.filter { it.isDigit() } == targetPhone?.filter { it.isDigit() }
                }

                if (isMatch) {
                    val callTypeStr = when (type) {
                        CallLog.Calls.INCOMING_TYPE -> "incoming"
                        CallLog.Calls.OUTGOING_TYPE -> "outgoing"
                        CallLog.Calls.MISSED_TYPE -> "missed"
                        CallLog.Calls.REJECTED_TYPE -> "rejected"
                        else -> "unknown"
                    }
                    return mapOf(
                        "number" to number,
                        "duration" to duration,
                        "type" to callTypeStr,
                        "timestamp" to date
                    )
                }
            }
        }
        return null
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == phonePermissionRequestCode) {
            val granted = checkHasPhonePermissions()
            pendingPhonePermissionResult?.success(granted)
            pendingPhonePermissionResult = null
        }
    }

    private fun stopCurrentRingtone() {
        ringtone?.let {
            if (it.isPlaying) it.stop()
        }
        ringtone = null
    }

    override fun onDestroy() {
        stopCurrentRingtone()
        super.onDestroy()
    }
}
