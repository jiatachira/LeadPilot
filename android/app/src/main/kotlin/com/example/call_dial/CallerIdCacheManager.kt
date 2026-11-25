package com.example.call_dial

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject

data class StudentCallerInfo(
    val name: String,
    val phone: String,
    val status: String,
    val location: String,
    val examType: String,
    val examYear: String,
    val lastComment: String,
    val streakCount: Int
) {
    fun toJson(): String {
        val obj = JSONObject()
        obj.put("name", name)
        obj.put("phone", phone)
        obj.put("status", status)
        obj.put("location", location)
        obj.put("examType", examType)
        obj.put("examYear", examYear)
        obj.put("lastComment", lastComment)
        obj.put("streakCount", streakCount)
        return obj.toString()
    }

    companion object {
        fun fromJson(jsonStr: String): StudentCallerInfo? {
            return try {
                val obj = JSONObject(jsonStr)
                StudentCallerInfo(
                    name = obj.optString("name", "Student Lead"),
                    phone = obj.optString("phone", ""),
                    status = obj.optString("status", "Pending"),
                    location = obj.optString("location", ""),
                    examType = obj.optString("examType", ""),
                    examYear = obj.optString("examYear", ""),
                    lastComment = obj.optString("lastComment", ""),
                    streakCount = obj.optInt("streakCount", 0)
                )
            } catch (e: Exception) {
                null
            }
        }
    }
}

object CallerIdCacheManager {
    private const val TAG = "CallerIdCacheManager"
    private const val PREFS_NAME = "leadpilot_caller_id_db"
    private const val PREFS_SETTINGS = "leadpilot_caller_id_settings"
    private const val KEY_ENABLED = "caller_id_enabled"
    private const val KEY_STUDENT_COUNT = "caller_id_student_count"

    fun normalizePhoneNumber(raw: String?): String {
        if (raw == null) return ""
        val digits = raw.filter { it.isDigit() }
        // Sri Lanka phone numbers (9 digits without leading 0 / +94)
        return if (digits.length >= 9) {
            digits.takeLast(9)
        } else {
            digits
        }
    }

    fun isCallerIdEnabled(context: Context): Boolean {
        val prefs = context.getSharedPreferences(PREFS_SETTINGS, Context.MODE_PRIVATE)
        return prefs.getBoolean(KEY_ENABLED, true)
    }

    fun setCallerIdEnabled(context: Context, enabled: Boolean) {
        val prefs = context.getSharedPreferences(PREFS_SETTINGS, Context.MODE_PRIVATE)
        prefs.edit().putBoolean(KEY_ENABLED, enabled).apply()
    }

    fun getCachedStudentCount(context: Context): Int {
        val prefs = context.getSharedPreferences(PREFS_SETTINGS, Context.MODE_PRIVATE)
        return prefs.getInt(KEY_STUDENT_COUNT, 0)
    }

    fun saveStudents(context: Context, studentsList: List<Map<String, Any>>) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        editor.clear()

        var validCount = 0
        for (item in studentsList) {
            val name = (item["name"] as? String)?.trim() ?: continue
            val phone = (item["phone"] as? String)?.trim() ?: ""
            if (name.isEmpty() || phone.isEmpty()) continue

            validCount++
            val status = (item["status"] as? String)?.trim() ?: "Pending"
            val location = (item["location"] as? String)?.trim() ?: ""
            val examType = (item["examType"] as? String)?.trim() ?: ""
            val examYear = (item["examYear"] as? String)?.trim() ?: ""
            val lastComment = (item["lastComment"] as? String)?.trim() ?: ""
            val streakCount = (item["streak"] as? Number)?.toInt() ?: 0
            val waPhone = (item["whatsappNumber"] as? String)?.trim() ?: ""

            val info = StudentCallerInfo(
                name = name,
                phone = phone,
                status = status,
                location = location,
                examType = examType,
                examYear = examYear,
                lastComment = lastComment,
                streakCount = streakCount
            )
            val jsonString = info.toJson()

            // Index primary phone under multiple formats
            indexPhoneVariations(editor, phone, jsonString)

            // Index WhatsApp phone under multiple formats if present
            if (waPhone.isNotEmpty()) {
                indexPhoneVariations(editor, waPhone, jsonString)
            }
        }
        editor.apply()

        // Persist count in settings prefs
        val settingsPrefs = context.getSharedPreferences(PREFS_SETTINGS, Context.MODE_PRIVATE)
        settingsPrefs.edit().putInt(KEY_STUDENT_COUNT, validCount).apply()

        Log.d(TAG, "Saved $validCount student leads to Caller ID offline cache.")
    }

    private fun indexPhoneVariations(editor: SharedPreferences.Editor, rawPhone: String, jsonString: String) {
        val norm = normalizePhoneNumber(rawPhone)
        if (norm.isNotEmpty()) {
            editor.putString(norm, jsonString)
            // also index with leading 0 (e.g. 0771234567)
            editor.putString("0$norm", jsonString)
            // also index with 94 prefix (e.g. 94771234567)
            editor.putString("94$norm", jsonString)
        }

        val digits = rawPhone.filter { it.isDigit() }
        if (digits.isNotEmpty()) {
            editor.putString(digits, jsonString)
        }

        val trimmed = rawPhone.trim()
        if (trimmed.isNotEmpty()) {
            editor.putString(trimmed, jsonString)
        }
    }

    fun lookupStudent(context: Context, rawPhone: String?): StudentCallerInfo? {
        if (rawPhone.isNullOrBlank()) {
            Log.d(TAG, "lookupStudent: rawPhone is null or blank")
            return null
        }

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

        // 1. Try normalized 9 digits (standard Sri Lankan format)
        val norm = normalizePhoneNumber(rawPhone)
        if (norm.isNotEmpty()) {
            val jsonStr = prefs.getString(norm, null)
            if (jsonStr != null) {
                Log.d(TAG, "lookupStudent: Matched via 9-digit norm: $norm")
                return StudentCallerInfo.fromJson(jsonStr)
            }
        }

        // 2. Try raw digits
        val digits = rawPhone.filter { it.isDigit() }
        if (digits.isNotEmpty()) {
            val jsonStr = prefs.getString(digits, null)
            if (jsonStr != null) {
                Log.d(TAG, "lookupStudent: Matched via digits: $digits")
                return StudentCallerInfo.fromJson(jsonStr)
            }
        }

        // 3. Try exact string match
        val rawTrimmed = rawPhone.trim()
        val rawMatch = prefs.getString(rawTrimmed, null)
        if (rawMatch != null) {
            Log.d(TAG, "lookupStudent: Matched via raw: $rawTrimmed")
            return StudentCallerInfo.fromJson(rawMatch)
        }

        Log.d(TAG, "lookupStudent: No match found for $rawPhone (norm: $norm, digits: $digits)")
        return null
    }

    private const val PREFS_PENDING_CALLS = "leadpilot_pending_call_logs"
    private const val KEY_PENDING_LIST = "pending_calls"

    fun addPendingCallLog(context: Context, phone: String, durationSec: Long, callType: String) {
        try {
            val prefs = context.getSharedPreferences(PREFS_PENDING_CALLS, Context.MODE_PRIVATE)
            val existing = getPendingCallLogs(context).toMutableList()
            val obj = JSONObject().apply {
                put("phone", phone)
                put("duration", durationSec)
                put("type", callType)
                put("timestamp", System.currentTimeMillis())
            }
            existing.add(obj)
            val arr = JSONArray()
            for (item in existing) {
                arr.put(item)
            }
            prefs.edit().putString(KEY_PENDING_LIST, arr.toString()).apply()
            addCallLog(context, phone, durationSec, callType)
            Log.d(TAG, "addPendingCallLog: Saved call log for $phone (duration=${durationSec}s, type=$callType)")
        } catch (e: Exception) {
            Log.e(TAG, "addPendingCallLog error", e)
        }
    }

    fun getPendingCallLogs(context: Context): List<JSONObject> {
        val prefs = context.getSharedPreferences(PREFS_PENDING_CALLS, Context.MODE_PRIVATE)
        val str = prefs.getString(KEY_PENDING_LIST, null) ?: return emptyList()
        return try {
            val arr = JSONArray(str)
            val list = mutableListOf<JSONObject>()
            for (i in 0 until arr.length()) {
                list.add(arr.getJSONObject(i))
            }
            list
        } catch (e: Exception) {
            emptyList()
        }
    }

    fun clearPendingCallLogs(context: Context) {
        val prefs = context.getSharedPreferences(PREFS_PENDING_CALLS, Context.MODE_PRIVATE)
        prefs.edit().clear().apply()
    }

    private const val PREFS_CALL_HISTORY = "leadpilot_call_history"
    private const val KEY_CALL_HISTORY_LIST = "call_history"
    private const val MAX_CALL_HISTORY = 200

    fun addCallLog(context: Context, phone: String, durationSec: Long, callType: String) {
        try {
            val prefs = context.getSharedPreferences(PREFS_CALL_HISTORY, Context.MODE_PRIVATE)
            val existing = getCallLogs(context).toMutableList()
            val obj = JSONObject().apply {
                put("phone", phone)
                put("duration", durationSec)
                put("type", callType)
                put("timestamp", System.currentTimeMillis())
            }
            existing.add(0, obj) // newest first
            val trimmed = if (existing.size > MAX_CALL_HISTORY) existing.subList(0, MAX_CALL_HISTORY) else existing
            val arr = JSONArray()
            for (item in trimmed) arr.put(item)
            prefs.edit().putString(KEY_CALL_HISTORY_LIST, arr.toString()).apply()
        } catch (e: Exception) {
            Log.e(TAG, "addCallLog error", e)
        }
    }

    fun getCallLogs(context: Context): List<JSONObject> {
        val prefs = context.getSharedPreferences(PREFS_CALL_HISTORY, Context.MODE_PRIVATE)
        val str = prefs.getString(KEY_CALL_HISTORY_LIST, null) ?: return emptyList()
        return try {
            val arr = JSONArray(str)
            val list = mutableListOf<JSONObject>()
            for (i in 0 until arr.length()) list.add(arr.getJSONObject(i))
            list
        } catch (e: Exception) {
            emptyList()
        }
    }
}
