package com.example.call_dial

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileInputStream

object CallRecorderManager {
    private const val TAG = "CallRecorderManager"
    private const val PREFS_NAME = "leadpilot_caller_id_prefs"
    private const val KEY_AUTO_RECORD = "auto_record_calls"
    private const val KEY_STORAGE_LOCATION = "recording_storage_location"
    private const val RECORDINGS_DIR = "CallRecordings"

    const val LOCATION_MUSIC = "music"
    const val LOCATION_DOCUMENTS = "documents"
    const val LOCATION_APP_INTERNAL = "internal"

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

    fun getRecordingStorageLocation(context: Context): String {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_STORAGE_LOCATION, LOCATION_MUSIC) ?: LOCATION_MUSIC
    }

    fun setRecordingStorageLocation(context: Context, locationKey: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_STORAGE_LOCATION, locationKey)
            .apply()
    }

    fun getRecordingsDir(context: Context): File {
        val location = getRecordingStorageLocation(context)
        val dir = try {
            when (location) {
                LOCATION_DOCUMENTS -> {
                    val docDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOCUMENTS)
                    File(docDir, "LeadPilotRecordings")
                }
                LOCATION_APP_INTERNAL -> {
                    val base = context.getExternalFilesDir(null) ?: context.filesDir
                    File(base, RECORDINGS_DIR)
                }
                else -> { // LOCATION_MUSIC (Default)
                    val musicDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC)
                    File(musicDir, "LeadPilotRecordings")
                }
            }
        } catch (_: Exception) {
            val base = context.getExternalFilesDir(null) ?: context.filesDir
            File(base, RECORDINGS_DIR)
        }

        try {
            if (!dir.exists()) {
                val created = dir.mkdirs()
                if (!created && !dir.exists()) {
                    val fallback = File(context.getExternalFilesDir(null) ?: context.filesDir, RECORDINGS_DIR)
                    if (!fallback.exists()) fallback.mkdirs()
                    return fallback
                }
            }
        } catch (_: Exception) {
            val fallback = File(context.getExternalFilesDir(null) ?: context.filesDir, RECORDINGS_DIR)
            if (!fallback.exists()) fallback.mkdirs()
            return fallback
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

        val sources = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            listOf(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                MediaRecorder.AudioSource.MIC
            )
        } else {
            listOf(
                MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                MediaRecorder.AudioSource.VOICE_CALL,
                MediaRecorder.AudioSource.MIC
            )
        }

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
                if (outFile.exists() && outFile.length() == 0L) {
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
        return if (savedPath != null && File(savedPath).exists() && File(savedPath).length() > 512) {
            savedPath
        } else {
            try {
                if (savedPath != null) File(savedPath).delete()
            } catch (_: Exception) {}
            null
        }
    }

    fun listRecordings(context: Context): List<Map<String, Any>> {
        val currentDir = getRecordingsDir(context)
        val internalDir = File(context.getExternalFilesDir(null) ?: context.filesDir, RECORDINGS_DIR)
        val dirs = listOfNotNull(currentDir, internalDir).distinctBy { it.absolutePath }

        val allFiles = mutableListOf<File>()
        for (dir in dirs) {
            if (dir.exists() && dir.isDirectory) {
                dir.listFiles { file ->
                    file.isFile && (file.name.endsWith(".m4a") || file.name.endsWith(".mp4") || file.name.endsWith(".3gp")) && file.length() > 512
                }?.let { allFiles.addAll(it) }
            }
        }

        return allFiles.distinctBy { it.name }.sortedByDescending { it.lastModified() }.map { file ->
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

    fun playRecording(path: String, context: Context? = null): Boolean {
        stopPlayback()
        return try {
            val file = File(path)
            if (!file.exists() || file.length() == 0L) {
                Log.w(TAG, "File does not exist or is empty: $path")
                return false
            }

            if (context != null) {
                val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
                am?.mode = AudioManager.MODE_NORMAL
                am?.isSpeakerphoneOn = false
            }

            val fis = FileInputStream(file)
            val mp = MediaPlayer().apply {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                            .build()
                    )
                } else {
                    @Suppress("DEPRECATION")
                    setAudioStreamType(AudioManager.STREAM_MUSIC)
                }
                setDataSource(fis.fd)
                prepare()
                setOnCompletionListener {
                    stopPlayback()
                }
                start()
            }
            fis.close()
            player = mp
            playingPath = path
            Log.d(TAG, "Successfully started playback: $path (size=${file.length()})")
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
