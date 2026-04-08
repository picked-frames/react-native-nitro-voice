package com.margelo.nitro.nitrottsstt

import androidx.annotation.Keep
import com.facebook.proguard.annotations.DoNotStrip
import com.margelo.nitro.core.ArrayBuffer
import com.margelo.nitro.core.Promise
import com.k2fsa.sherpa.onnx.Vad
import com.k2fsa.sherpa.onnx.VadModelConfig
import com.k2fsa.sherpa.onnx.SileroVadModelConfig
import java.nio.ByteBuffer
import java.nio.ByteOrder

@Keep
@DoNotStrip
class HybridVAD : HybridVADSpec() {

  // State
  private var vad: Vad? = null
  private var onSpeechStartCallback: (() -> Unit)? = null
  private var onSpeechEndCallback: ((ArrayBuffer) -> Unit)? = null
  private var wasSpeaking = false

  private val processingThread = java.util.concurrent.Executors.newSingleThreadExecutor()

  // MARK: - Initialize

  override fun initialize(config: VADConfig): Promise<Unit> {
    return Promise.async {
      val vadConfig = VadModelConfig(
        sileroVad = SileroVadModelConfig(
          model = config.modelPath,
          threshold = config.threshold?.toFloat() ?: 0.5f,
          minSilenceDuration = config.minSilenceDuration?.toFloat() ?: 0.5f,
          minSpeechDuration = config.minSpeechDuration?.toFloat() ?: 0.25f,
          windowSize = 512
        ),
        sampleRate = 16000,
        numThreads = 1,
        provider = "cpu",
        debug = false
      )

      vad = Vad(vadConfig, bufferSizeInSeconds = 30.0f)
        ?: throw IllegalStateException("Failed to create VAD. Check model file at: ${config.modelPath}")
    }
  }

  // MARK: - Start

  override fun start(
    onSpeechStart: () -> Unit,
    onSpeechEnd: (audio: ArrayBuffer) -> Unit
  ): () -> Unit {
    onSpeechStartCallback = onSpeechStart
    onSpeechEndCallback = onSpeechEnd
    wasSpeaking = false

    return {
      onSpeechStartCallback = null
      onSpeechEndCallback = null
    }
  }

  // MARK: - Process Chunk

  override fun processChunk(samples: ArrayBuffer): Unit {
    processingThread.execute {
      val vadInstance = vad ?: return@execute

      val byteBuffer = ByteBuffer.wrap(
        ByteArray(samples.size).also {
          samples.getBuffer(ByteBuffer.wrap(it))
        }
      ).order(ByteOrder.nativeOrder())
      val floatBuffer = byteBuffer.asFloatBuffer()
      val floats = FloatArray(floatBuffer.remaining())
      floatBuffer.get(floats)

      vadInstance.acceptWaveform(floats)

      val isSpeaking = vadInstance.isSpeechDetected()

      // Detect speech start
      if (isSpeaking && !wasSpeaking) {
        wasSpeaking = true
        onSpeechStartCallback?.invoke()
      }

      // Check for completed speech segments
      while (!vadInstance.empty()) {
        val segment = vadInstance.front()
        val segmentSamples = segment.samples

        if (segmentSamples.isNotEmpty()) {
          val byteSize = segmentSamples.size * 4 // Float = 4 bytes
          val buffer = ArrayBuffer.allocate(byteSize)
          val segmentByteBuffer = ByteBuffer.allocate(byteSize).order(ByteOrder.nativeOrder())
          segmentByteBuffer.asFloatBuffer().put(segmentSamples)
          buffer.getBuffer(segmentByteBuffer)
          onSpeechEndCallback?.invoke(buffer)
        }

        vadInstance.pop()
        wasSpeaking = false
      }
    }
  }

  // MARK: - Reset / Destroy

  override fun reset(): Unit {
    vad?.reset()
    wasSpeaking = false
  }

  override fun destroy(): Unit {
    onSpeechStartCallback = null
    onSpeechEndCallback = null
    vad?.release()
    vad = null
    processingThread.shutdown()
  }
}
