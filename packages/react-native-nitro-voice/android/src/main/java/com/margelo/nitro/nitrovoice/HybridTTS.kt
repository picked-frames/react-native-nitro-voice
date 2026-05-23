package com.margelo.nitro.nitrovoice

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.ArrayBuffer
import com.margelo.nitro.core.Promise
import com.k2fsa.sherpa.onnx.OfflineTts
import com.k2fsa.sherpa.onnx.OfflineTtsConfig
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsVitsModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsKokoroModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsMatchaModelConfig
import com.k2fsa.sherpa.onnx.GenerationConfig
import java.io.File
import java.nio.ByteOrder

@Keep
@DoNotStrip
class HybridTTS : HybridTTSSpec() {

  // State
  private var tts: OfflineTts? = null
  @Volatile private var isSpeaking = false
  private var modelConfig: TTSConfig? = null
  private var audioTrack: AudioTrack? = null

  // MARK: - Properties

  override val sampleRate: Double
    get() = tts?.sampleRate()?.toDouble() ?: 0.0

  override val numSpeakers: Double
    get() = tts?.numSpeakers()?.toDouble() ?: 0.0

  // MARK: - Initialize

  override fun initialize(config: TTSConfig): Promise<Unit> {
    return Promise.async {
      modelConfig = config
      val modelDir = config.modelDir

      val dataDir = listOf("espeak-ng-data", "data")
        .map { "$modelDir/$it" }
        .firstOrNull { File(it).exists() } ?: ""

      val ttsModelConfig = OfflineTtsModelConfig(
        vits = if (config.type == TTSModelType.VITS) {
          OfflineTtsVitsModelConfig(
            model = "$modelDir/model.onnx",
            tokens = "$modelDir/tokens.txt",
            dataDir = dataDir,
            lexicon = if (File("$modelDir/lexicon.txt").exists()) "$modelDir/lexicon.txt" else "",
            lengthScale = 1.0f / (config.speed?.toFloat() ?: 1.0f)
          )
        } else OfflineTtsVitsModelConfig(),
        kokoro = if (config.type == TTSModelType.KOKORO) {
          OfflineTtsKokoroModelConfig(
            model = "$modelDir/model.onnx",
            voices = "$modelDir/voices.bin",
            tokens = "$modelDir/tokens.txt",
            dataDir = dataDir,
            lengthScale = 1.0f / (config.speed?.toFloat() ?: 1.0f)
          )
        } else OfflineTtsKokoroModelConfig(),
        matcha = if (config.type == TTSModelType.MATCHA) {
          OfflineTtsMatchaModelConfig(
            acousticModel = "$modelDir/acoustic_model.onnx",
            vocoder = "$modelDir/vocoder.onnx",
            tokens = "$modelDir/tokens.txt",
            dataDir = dataDir,
            lengthScale = 1.0f / (config.speed?.toFloat() ?: 1.0f)
          )
        } else OfflineTtsMatchaModelConfig(),
        numThreads = 2,
        provider = "cpu",
        debug = false
      )

      val ruleFstsPath = "$modelDir/rule.fst"
      val ttsConfig = OfflineTtsConfig(
        model = ttsModelConfig,
        ruleFsts = if (File(ruleFstsPath).exists()) ruleFstsPath else "",
        maxNumSentences = 1
      )

      tts = OfflineTts(null, ttsConfig)
        ?: throw IllegalStateException("Failed to create TTS engine. Check model files in: $modelDir")

      setupAudioTrack(tts!!.sampleRate())
    }
  }

  private fun setupAudioTrack(sampleRate: Int) {
    audioTrack?.release()
    val bufferSize = AudioTrack.getMinBufferSize(
      sampleRate,
      AudioFormat.CHANNEL_OUT_MONO,
      AudioFormat.ENCODING_PCM_FLOAT
    ).coerceAtLeast(sampleRate * 4) // at least 1 second buffer
    audioTrack = AudioTrack.Builder()
      .setAudioAttributes(
        AudioAttributes.Builder()
          .setUsage(AudioAttributes.USAGE_MEDIA)
          .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
          .build()
      )
      .setAudioFormat(
        AudioFormat.Builder()
          .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
          .setSampleRate(sampleRate)
          .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
          .build()
      )
      .setBufferSizeInBytes(bufferSize)
      .setTransferMode(AudioTrack.MODE_STREAM)
      .build()
    audioTrack?.play()
  }

  // MARK: - Speak

  override fun speak(
    text: String,
    onAudioChunk: (samples: ArrayBuffer, sampleRate: Double) -> Unit,
    onComplete: () -> Unit
  ): Promise<Unit> {
    return Promise.async {
      val ttsInstance = tts
        ?: throw IllegalStateException("Not initialized. Call initialize() first.")

      isSpeaking = true

      val genConfig = GenerationConfig(
        sid = modelConfig?.speakerId?.toInt() ?: 0,
        speed = modelConfig?.speed?.toFloat() ?: 1.0f
      )

      val currentSampleRate = ttsInstance.sampleRate().toDouble()

      val audio = ttsInstance.generateWithConfig(text, genConfig)

      if (isSpeaking && audio.samples.isNotEmpty()) {
        // JS callback
        val byteSize = audio.samples.size * 4 // Float = 4 bytes
        val buffer = ArrayBuffer.allocate(byteSize)
        buffer.getBuffer(false).order(ByteOrder.nativeOrder()).asFloatBuffer().put(audio.samples)
        onAudioChunk(buffer, currentSampleRate)

        // Native playback via AudioTrack
        val track = audioTrack
        if (track != null && track.state == AudioTrack.STATE_INITIALIZED) {
          if (track.playState != AudioTrack.PLAYSTATE_PLAYING) track.play()
          track.write(audio.samples, 0, audio.samples.size, AudioTrack.WRITE_BLOCKING)
        }
      }

      isSpeaking = false
      onComplete()
    }
  }

  // MARK: - Stop / Destroy

  override fun stop(): Promise<Unit> {
    return Promise.async {
      isSpeaking = false
      audioTrack?.pause()
      audioTrack?.flush()
      audioTrack?.play() // ready for next speak()
    }
  }

  override fun destroy(): Promise<Unit> {
    return Promise.async {
      isSpeaking = false
      audioTrack?.stop()
      audioTrack?.release()
      audioTrack = null
      tts?.release()
      tts = null
    }
  }
}
