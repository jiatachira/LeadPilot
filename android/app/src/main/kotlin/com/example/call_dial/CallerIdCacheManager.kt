package com.example.call_dial

import android.content.Context
import android.content.SharedPreferences
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
    private const val PREFS_NAME = "leadpilot_caller_id_db"
    private const val PREFS_SETTINGS = "leadpilot_caller_id_settings"
    private const val KEY_ENABLED = "caller_id_enabled"

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

    fun saveStudents(context: Context, studentsList: List<Map<String, Any>>) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val editor = prefs.edit()
        editor.clear()

        for (item in studentsList) {
            val name = (item["name"] as? String)?.trim() ?: continue
            val phone = (item["phone"] as? String)?.trim() ?: ""
            if (name.isEmpty() || phone.isEmpty()) continue

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

            val normPhone = normalizePhoneNumber(phone)
            if (normPhone.isNotEmpty()) {
                editor.putString(normPhone, jsonString)
            }

            if (waPhone.isNotEmpty()) {
                val normWa = normalizePhoneNumber(waPhone)
                if (normWa.isNotEmpty() && normWa != normPhone) {
                    editor.putString(normWa, jsonString)
                }
            }
        }
        editor.apply()
    }

    fun lookupStudent(context: Context, rawPhone: String?): StudentCallerInfo? {
        if (rawPhone.isNullOrBlank()) return null
        val norm = normalizePhoneNumber(rawPhone)
        if (norm.isEmpty()) return null

        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        var jsonStr = prefs.getString(norm, null)

        // Fallback to exact digits match if 9-digit match wasn't found
        if (jsonStr == null) {
            val digits = rawPhone.filter { it.isDigit() }
            if (digits.isNotEmpty() && digits != norm) {
                jsonStr = prefs.getString(digits, null)
            }
        }

        return jsonStr?.let { StudentCallerInfo.fromJson(it) }
    }
}
