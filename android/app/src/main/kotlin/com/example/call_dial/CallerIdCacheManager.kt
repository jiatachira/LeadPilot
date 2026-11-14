package com.example.call_dial

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
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
}
