package com.margelo.nitro.nitrovoice

import android.Manifest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.ArrayBuffer
import com.margelo.nitro.core.Promise
import com.k2fsa.sherpa.onnx.OnlineRecognizer
import com.k2fsa.sherpa.onnx.OnlineRecognizerConfig
import com.k2fsa.sherpa.onnx.OnlineModelConfig
import com.k2fsa.sherpa.onnx.OnlineTransducerModelConfig
import com.k2fsa.sherpa.onnx.OnlineParaformerModelConfig
import com.k2fsa.sherpa.onnx.OnlineNemoCtcModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineTransducerModelConfig
import com.k2fsa.sherpa.onnx.OfflineParaformerModelConfig
import com.k2fsa.sherpa.onnx.OfflineNemoCtcModelConfig
import com.k2fsa.sherpa.onnx.OfflineWhisperModelConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import com.k2fsa.sherpa.onnx.FeatureConfig
import java.nio.ByteBuffer
import java.nio.ByteOrder

@Keep
@DoNotStrip
class HybridSTT : HybridSTTSpec() {

  // State
  private var onlineRecognizer: OnlineRecognizer? = null
  private var offlineRecognizer: OfflineRecognizer? = null
  private var vad: Vad? = null
  private var audioCapture: AudioCaptureHelper? = null
  @Volatile private var isRunning = false
  private var modelConfig: STTConfig? = null

  // Callbacks
  private var onPartialCallback: ((String) -> Unit)? = null
  private var onFinalCallback: ((String) -> Unit)? = null
  private var onTranscriptCallback: ((String) -> Unit)? = null

  // Processing thread
  private val processingThread = java.util.concurrent.Executors.newSingleThreadExecutor()

  // MARK: - Initialize

  override fun initialize(config: STTConfig): Promise<Unit> {
    return Promise.async {
      modelConfig = config
    }
  }

  // MARK: - Streaming Mode

  override fun startStreaming(
    onPartial: (text: String) -> Unit,
    onFinal: (text: String) -> Unit
  ): Promise<Unit> {
    return Promise.async {
      val config = modelConfig
        ?: throw IllegalStateException("Not initialized. Call initialize() first.")

      onPartialCallback = onPartial
      onFinalCallback = onFinal
      isRunning = true

      val modelDir = config.modelDir

      val onlineModelConfig = OnlineModelConfig(
        transducer = if (config.type == STTModelType.TRANSDUCER) {
          OnlineTransducerModelConfig(
            encoder = "$modelDir/encoder.onnx",
            decoder = "$modelDir/decoder.onnx",
            joiner = "$modelDir/joiner.onnx"
          )
        } else OnlineTransducerModelConfig(),
        paraformer = if (config.type == STTModelType.PARAFORMER) {
          OnlineParaformerModelConfig(
            encoder = "$modelDir/encoder.onnx",
            decoder = "$modelDir/decoder.onnx"
          )
        } else OnlineParaformerModelConfig(),
        nemoCtc = if (config.type == STTModelType.NEMO_CTC) {
          OnlineNemoCtcModelConfig(model = "$modelDir/model.onnx")
        } else OnlineNemoCtcModelConfig(),
        tokens = "$modelDir/tokens.txt",
        numThreads = 2,
        provider = "cpu",
        debug = false
      )

      if (config.type != STTModelType.TRANSDUCER &&
          config.type != STTModelType.PARAFORMER &&
          config.type != STTModelType.NEMO_CTC) {
        throw IllegalArgumentException(
          "Model type '${config.type}' is not supported for streaming mode. " +
          "Use transducer, paraformer, or nemo_ctc."
        )
      }

      val recognizerConfig = OnlineRecognizerConfig(
        featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
        modelConfig = onlineModelConfig,
        decodingMethod = "greedy_search",
        enableEndpoint = true,
        rule1MinTrailingSilence = 2.4f,
        rule2MinTrailingSilence = 1.2f,
        rule3MinUtteranceLength = 20.0f
      )

      onlineRecognizer = OnlineRecognizer(recognizerConfig)
    }
  }

  // MARK: - VAD-Gated Batch Mode

  override fun startVADGated(
    vadModelPath: String,
    onTranscript: (text: String) -> Unit
  ): Promise<Unit> {
    return Promise.async {
      val config = modelConfig
        ?: throw IllegalStateException("Not initialized. Call initialize() first.")

      onTranscriptCallback = onTranscript
      isRunning = true

      val modelDir = config.modelDir

      // Create VAD
      val vadConfig = VadModelConfig(
        sileroVad = SileroVadModelConfig(
          model = vadModelPath,
          threshold = 0.5f,
          minSilenceDuration = 0.5f,
          minSpeechDuration = 0.25f,
          windowSize = 512
        ),
        sampleRate = 16000,
        numThreads = 1,
        provider = "cpu",
        debug = false
      )
      vad = Vad(vadConfig, bufferSizeInSeconds = 30.0f)

      // Create offline recognizer
      val offlineModelConfig = OfflineModelConfig(
        transducer = if (config.type == STTModelType.TRANSDUCER) {
          OfflineTransducerModelConfig(
            encoder = "$modelDir/encoder.onnx",
            decoder = "$modelDir/decoder.onnx",
            joiner = "$modelDir/joiner.onnx"
          )
        } else OfflineTransducerModelConfig(),
        whisper = if (config.type == STTModelType.WHISPER) {
          OfflineWhisperModelConfig(
            encoder = "$modelDir/encoder.onnx",
            decoder = "$modelDir/decoder.onnx",
            language = config.language ?: "en",
            task = "transcribe"
          )
        } else OfflineWhisperModelConfig(),
        paraformer = if (config.type == STTModelType.PARAFORMER) {
          OfflineParaformerModelConfig(model = "$modelDir/model.onnx")
        } else OfflineParaformerModelConfig(),
        nemoCtc = if (config.type == STTModelType.NEMO_CTC) {
          OfflineNemoCtcModelConfig(model = "$modelDir/model.onnx")
        } else OfflineNemoCtcModelConfig(),
        senseVoice = if (config.type == STTModelType.SENSE_VOICE) {
          OfflineSenseVoiceModelConfig(
            model = "$modelDir/model.onnx",
            language = config.language ?: ""
          )
        } else OfflineSenseVoiceModelConfig(),
        tokens = "$modelDir/tokens.txt",
        numThreads = 2,
        provider = "cpu",
        debug = false
      )

      val offlineConfig = OfflineRecognizerConfig(
        featConfig = FeatureConfig(sampleRate = 16000, featureDim = 80),
        modelConfig = offlineModelConfig,
        decodingMethod = "greedy_search"
      )

      offlineRecognizer = OfflineRecognizer(offlineConfig)
    }
  }

  // MARK: - Audio Input

  override fun feedAudio(samples: ArrayBuffer, sampleRate: Double): Unit {
    if (!isRunning) return

    processingThread.execute {
      val byteBuffer = ByteBuffer.wrap(
        ByteArray(samples.size).also {
          samples.getBuffer(ByteBuffer.wrap(it))
        }
      ).order(ByteOrder.nativeOrder())
      val floatBuffer = byteBuffer.asFloatBuffer()
      val floats = FloatArray(floatBuffer.remaining())
      floatBuffer.get(floats)

      // Resample to 16kHz if needed
      val targetRate = 16000.0
      val audioData = if (kotlin.math.abs(sampleRate - targetRate) < 1.0) {
        floats
      } else {
        resample(floats, sampleRate, targetRate)
      }

      processAudioChunk(audioData)
    }
  }

  override fun startMic(): Promise<Unit> {
    return Promise.async {
      val capture = AudioCaptureHelper { samples ->
        if (isRunning) {
          processingThread.execute {
            processAudioChunk(samples)
          }
        }
      }
      capture.start()
      audioCapture = capture
    }
  }

  override fun stopMic(): Unit {
    audioCapture?.stop()
    audioCapture = null
  }

  // MARK: - Stop / Destroy

  override fun stop(): Promise<Unit> {
    return Promise.async {
      isRunning = false
      onPartialCallback = null
      onFinalCallback = null
      onTranscriptCallback = null
    }
  }

  override fun destroy(): Promise<Unit> {
    return Promise.async {
      isRunning = false
      stopMic()

      onlineRecognizer?.release()
      onlineRecognizer = null
      offlineRecognizer?.release()
      offlineRecognizer = null
      vad?.release()
      vad = null

      processingThread.shutdown()
    }
  }

  // MARK: - Internal Processing

  private fun processAudioChunk(samples: FloatArray) {
    if (!isRunning) return

    onlineRecognizer?.let { recognizer ->
      processStreamingChunk(samples, recognizer)
    } ?: vad?.let {
      processVADChunk(samples)
    }
  }

  private fun processStreamingChunk(samples: FloatArray, recognizer: OnlineRecognizer) {
    val stream = recognizer.createStream()
    stream.acceptWaveform(samples, 16000)

    while (recognizer.isReady(stream)) {
      recognizer.decode(stream)
    }

    val text = recognizer.getResult(stream).text
    if (text.isNotEmpty()) {
      onPartialCallback?.invoke(text)
    }

    if (recognizer.isEndpoint(stream)) {
      if (text.isNotEmpty()) {
        onFinalCallback?.invoke(text)
      }
      recognizer.reset(stream)
    }
  }

  private fun processVADChunk(samples: FloatArray) {
    val vadInstance = vad ?: return

    vadInstance.acceptWaveform(samples)

    while (!vadInstance.empty()) {
      val segment = vadInstance.front()
      decodeOfflineSegment(segment.samples)
      vadInstance.pop()
    }
  }

  private fun decodeOfflineSegment(samples: FloatArray) {
    val recognizer = offlineRecognizer ?: return
    if (samples.isEmpty()) return

    val stream = recognizer.createStream()
    stream.acceptWaveform(samples, 16000)
    recognizer.decode(stream)
    val text = recognizer.getResult(stream).text.trim()

    if (text.isNotEmpty()) {
      onTranscriptCallback?.invoke(text)
    }
  }

  // MARK: - Helpers

  private fun resample(input: FloatArray, fromRate: Double, toRate: Double): FloatArray {
    val ratio = toRate / fromRate
    val outputCount = (input.size * ratio).toInt()
    return FloatArray(outputCount) { i ->
      val srcIndex = (i.toDouble() / ratio).toInt().coerceAtMost(input.size - 1)
      input[srcIndex]
    }
  }
}
