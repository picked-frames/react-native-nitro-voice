package com.margelo.nitro.nitrottsstt

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder

internal class AudioCaptureHelper(
  private val onAudioChunk: (FloatArray) -> Unit
) {
  private var audioRecord: AudioRecord? = null
  @Volatile private var isRecording = false
  private var recordingThread: Thread? = null

  companion object {
    private const val SAMPLE_RATE = 16000
    private const val CHANNEL_CONFIG = AudioFormat.CHANNEL_IN_MONO
    private const val AUDIO_FORMAT = AudioFormat.ENCODING_PCM_FLOAT
  }

  fun start() {
    val minBufferSize = AudioRecord.getMinBufferSize(SAMPLE_RATE, CHANNEL_CONFIG, AUDIO_FORMAT)
    val bufferSize = maxOf(minBufferSize, SAMPLE_RATE) // At least 1 second of buffer

    audioRecord = AudioRecord(
      MediaRecorder.AudioSource.MIC,
      SAMPLE_RATE,
      CHANNEL_CONFIG,
      AUDIO_FORMAT,
      bufferSize * 4 // Float = 4 bytes
    )

    if (audioRecord?.state != AudioRecord.STATE_INITIALIZED) {
      audioRecord?.release()
      audioRecord = null
      throw IllegalStateException("Failed to initialize AudioRecord. Check microphone permissions.")
    }

    isRecording = true
    audioRecord?.startRecording()

    recordingThread = Thread {
      val chunkSize = 512 // Match VAD window size
      val buffer = FloatArray(chunkSize)

      while (isRecording) {
        val read = audioRecord?.read(buffer, 0, chunkSize, AudioRecord.READ_BLOCKING) ?: -1
        if (read > 0) {
          val chunk = if (read == chunkSize) buffer else buffer.copyOf(read)
          onAudioChunk(chunk)
        }
      }
    }.apply {
      name = "NitroTtsStt-AudioCapture"
      priority = Thread.MAX_PRIORITY
      start()
    }
  }

  fun stop() {
    isRecording = false
    recordingThread?.join(1000)
    recordingThread = null
    audioRecord?.stop()
    audioRecord?.release()
    audioRecord = null
  }
}
