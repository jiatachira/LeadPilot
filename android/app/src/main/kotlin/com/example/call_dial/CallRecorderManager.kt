package com.example.call_dial

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File

object CallRecorderManager {
    private const val TAG = "CallRecorderManager"
    private const val PREFS_NAME = "leadpilot_caller_id_prefs"
    private const val KEY_AUTO_RECORD = "auto_record_calls"
    private const val RECORDINGS_DIR = "CallRecordings"

    private var recorder: MediaRecorder? = null
    private var currentFile: File? = null
    @Volatile
    var isRecording: Boolean = false
        private set
    @Volatile
    var recordingStartedAtMs: Long = 0L
        private set

    private var player: MediaPlayer? = null
    @Volatile
    var playingPath: String? = null
        private set

    fun isAutoRecordEnabled(context: Context): Boolean {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_AUTO_RECORD, false)
    }

    fun setAutoRecordEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_AUTO_RECORD, enabled)
            .apply()
    }

    fun getRecordingsDir(context: Context): File {
        val base = context.getExternalFilesDir(null) ?: context.filesDir
        val dir = File(base, RECORDINGS_DIR)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }

    fun startRecording(context: Context, phone: String): Boolean {
        if (isRecording) return true
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "RECORD_AUDIO permission not granted")
            return false
        }

        val sanitizedPhone = phone.replace(Regex("[^0-9+]"), "").ifBlank { "unknown" }
        val timestamp = System.currentTimeMillis()
        val outFile = File(getRecordingsDir(context), "call_${sanitizedPhone}_$timestamp.m4a")

        val sources = listOf(
            MediaRecorder.AudioSource.VOICE_CALL,
            MediaRecorder.AudioSource.VOICE_COMMUNICATION,
            MediaRecorder.AudioSource.MIC
        )

        for (source in sources) {
            var mr: MediaRecorder? = null
            try {
                mr = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    MediaRecorder(context)
                } else {
                    @Suppress("DEPRECATION")
                    MediaRecorder()
                }
                mr.setAudioSource(source)
                mr.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                mr.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                mr.setAudioEncodingBitRate(96000)
                mr.setAudioSamplingRate(44100)
                mr.setOutputFile(outFile.absolutePath)
                mr.prepare()
                mr.start()

                recorder = mr
                currentFile = outFile
                isRecording = true
                recordingStartedAtMs = System.currentTimeMillis()
                Log.d(TAG, "Started call recording with source=$source at ${outFile.absolutePath}")
                return true
            } catch (e: Exception) {
                Log.w(TAG, "AudioSource $source failed: ${e.message}")
                try {
                    mr?.reset()
                    mr?.release()
                } catch (_: Exception) {}
                if (outFile.exists()) {
                    outFile.delete()
                }
            }
        }

        isRecording = false
        currentFile = null
        recordingStartedAtMs = 0L
        return false
    }

    fun stopRecording(): String? {
        if (!isRecording) return null
        val savedPath = currentFile?.absolutePath
        try {
            recorder?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "stop() error: ${e.message}")
            try {
                currentFile?.delete()
            } catch (_: Exception) {}
        } finally {
            try {
                recorder?.reset()
                recorder?.release()
            } catch (_: Exception) {}
            recorder = null
            isRecording = false
            recordingStartedAtMs = 0L
            currentFile = null
        }
        return if (savedPath != null && File(savedPath).exists() && File(savedPath).length() > 0) {
            savedPath
        } else {
            null
        }
    }

    fun listRecordings(context: Context): List<Map<String, Any>> {
        val dir = getRecordingsDir(context)
        val files = dir.listFiles { file ->
            file.isFile && (file.name.endsWith(".m4a") || file.name.endsWith(".mp4") || file.name.endsWith(".3gp")) && file.length() > 0
        } ?: return emptyList()

        return files.sortedByDescending { it.lastModified() }.map { file ->
            // Expected format: call_<phone>_<timestampMs>.m4a
            val baseName = file.nameWithoutExtension
            val parts = baseName.split("_")
            val phone = if (parts.size >= 3) parts[1] else ""
            val ts = if (parts.size >= 3) parts[2].toLongOrNull() ?: file.lastModified() else file.lastModified()
            mapOf(
                "path" to file.absolutePath,
                "name" to file.name,
                "phone" to phone,
                "timestampMs" to ts,
                "sizeBytes" to file.length()
            )
        }
    }

    fun deleteRecording(path: String): Boolean {
        if (playingPath == path) {
            stopPlayback()
        }
        return try {
            val file = File(path)
            file.exists() && file.delete()
        } catch (_: Exception) {
            false
        }
    }

    fun playRecording(path: String): Boolean {
        stopPlayback()
        return try {
            val file = File(path)
            if (!file.exists()) return false
            val mp = MediaPlayer().apply {
                setDataSource(path)
                prepare()
                setOnCompletionListener {
                    stopPlayback()
                }
                start()
            }
            player = mp
            playingPath = path
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to play recording", e)
            stopPlayback()
            false
        }
    }

    fun stopPlayback() {
        try {
            player?.stop()
        } catch (_: Exception) {}
        try {
            player?.release()
        } catch (_: Exception) {}
        player = null
        playingPath = null
    }

    fun getPlaybackStatus(): Map<String, Any?> {
        val mp = player
        val isPlaying = try { mp?.isPlaying == true } catch (_: Exception) { false }
        val positionMs = try { if (mp != null) mp.currentPosition else 0 } catch (_: Exception) { 0 }
        val durationMs = try { if (mp != null) mp.duration else 0 } catch (_: Exception) { 0 }
        return mapOf(
            "playingPath" to playingPath,
            "isPlaying" to isPlaying,
            "positionMs" to positionMs,
            "durationMs" to durationMs
        )
    }
}
