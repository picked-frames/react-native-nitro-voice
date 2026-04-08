package com.margelo.nitro.nitrottsstt

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
import java.nio.ByteBuffer
import java.nio.ByteOrder

@Keep
@DoNotStrip
class HybridTTS : HybridTTSSpec() {

  // State
  private var tts: OfflineTts? = null
  @Volatile private var isSpeaking = false
  private var modelConfig: TTSConfig? = null

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

      val ttsModelConfig = OfflineTtsModelConfig(
        vits = if (config.type == TTSModelType.VITS) {
          OfflineTtsVitsModelConfig(
            model = "$modelDir/model.onnx",
            tokens = "$modelDir/tokens.txt",
            dataDir = "$modelDir/data",
            lexicon = if (File("$modelDir/lexicon.txt").exists()) "$modelDir/lexicon.txt" else "",
            lengthScale = 1.0f / (config.speed?.toFloat() ?: 1.0f)
          )
        } else OfflineTtsVitsModelConfig(),
        kokoro = if (config.type == TTSModelType.KOKORO) {
          OfflineTtsKokoroModelConfig(
            model = "$modelDir/model.onnx",
            voices = "$modelDir/voices.bin",
            tokens = "$modelDir/tokens.txt",
            dataDir = "$modelDir/data",
            lengthScale = 1.0f / (config.speed?.toFloat() ?: 1.0f)
          )
        } else OfflineTtsKokoroModelConfig(),
        matcha = if (config.type == TTSModelType.MATCHA) {
          OfflineTtsMatchaModelConfig(
            acousticModel = "$modelDir/acoustic_model.onnx",
            vocoder = "$modelDir/vocoder.onnx",
            tokens = "$modelDir/tokens.txt",
            dataDir = "$modelDir/data",
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

      tts = OfflineTts(ttsConfig)
        ?: throw IllegalStateException("Failed to create TTS engine. Check model files in: $modelDir")
    }
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

      // Generate with streaming callback
      val audio = ttsInstance.generateWithCallback(
        text = text,
        config = genConfig,
        callback = { samplesArray ->
          if (!isSpeaking) return@generateWithCallback 0

          if (samplesArray.isNotEmpty()) {
            val byteSize = samplesArray.size * 4 // Float = 4 bytes
            val buffer = ArrayBuffer.allocate(byteSize)
            val byteBuffer = ByteBuffer.allocate(byteSize).order(ByteOrder.nativeOrder())
            byteBuffer.asFloatBuffer().put(samplesArray)
            buffer.getBuffer(byteBuffer)
            onAudioChunk(buffer, currentSampleRate)
          }
          1 // continue generation
        }
      )

      isSpeaking = false
      onComplete()
    }
  }

  // MARK: - Stop / Destroy

  override fun stop(): Promise<Unit> {
    return Promise.async {
      isSpeaking = false
    }
  }

  override fun destroy(): Promise<Unit> {
    return Promise.async {
      isSpeaking = false
      tts?.release()
      tts = null
    }
  }
}
