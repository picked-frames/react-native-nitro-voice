/**
 * NitroVoice Example App
 * Demonstrates VAD-gated Whisper STT and Kokoro TTS
 *
 * Models are downloaded on first run using:
 *   - react-native-fs       → large ONNX binaries (stream directly to disk with progress)
 *   - react-native-nitro-fetch → small text files (fetch into memory, write via RNFS)
 */

import React, { useState, useRef, useCallback, useEffect } from 'react';
import {
  ScrollView,
  StatusBar,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
  useColorScheme,
  Platform,
  PermissionsAndroid,
  ActivityIndicator,
} from 'react-native';
import { NitroSTT, NitroTTS } from 'react-native-nitro-voice';
import type { STTConfig, TTSConfig } from 'react-native-nitro-voice';
import { SafeAreaView } from 'react-native-safe-area-context';
import RNFS from 'react-native-fs';
import { fetch as nitroFetch } from 'react-native-nitro-fetch';

// ─── MODEL PATHS ─────────────────────────────────────────────────────────────
const MODELS_DIR = `${RNFS.DocumentDirectoryPath}/nitro-voice-models`;
const WHISPER_DIR = `${MODELS_DIR}/whisper`;
const VAD_MODEL_PATH = `${MODELS_DIR}/silero_vad.onnx`;

// ─── DOWNLOAD SOURCES ────────────────────────────────────────────────────────
// Whisper Tiny EN (int8 quantized): encoder ~12.9 MB, decoder ~89.9 MB
const HF_WHISPER =
  'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny.en/resolve/main';

type ModelFile = {
  label: string;
  url: string;
  dest: string;
  /** When true, uses react-native-nitro-fetch (small files that fit in memory) */
  useNitroFetch?: boolean;
};

const WHISPER_FILES: ModelFile[] = [
  {
    label: 'encoder.onnx (12.9 MB)',
    url: `${HF_WHISPER}/tiny.en-encoder.int8.onnx`,
    dest: `${WHISPER_DIR}/encoder.onnx`,
  },
  {
    label: 'decoder.onnx (89.9 MB)',
    url: `${HF_WHISPER}/tiny.en-decoder.int8.onnx`,
    dest: `${WHISPER_DIR}/decoder.onnx`,
  },
  {
    // Small text file — use react-native-nitro-fetch to fetch into memory
    label: 'tokens.txt (836 kB)',
    url: `${HF_WHISPER}/tiny.en-tokens.txt`,
    dest: `${WHISPER_DIR}/tokens.txt`,
    useNitroFetch: true,
  },
];

const VAD_FILE: ModelFile = {
  label: 'silero_vad.onnx (~2 MB)',
  url: 'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
  dest: VAD_MODEL_PATH,
};

const ALL_MODEL_FILES: ModelFile[] = [...WHISPER_FILES, VAD_FILE];

// ─── STATIC CONFIGS (paths are stable after first download) ──────────────────
const STT_CONFIG: STTConfig = {
  modelDir: WHISPER_DIR,
  type: 'whisper',
  language: 'en',
};

const TTS_CONFIG: TTSConfig = {
  modelDir: `${MODELS_DIR}/kokoro`,
  type: 'kokoro',
  speed: 1.0,
};

// ─── DOWNLOAD HELPERS ────────────────────────────────────────────────────────
async function requestMicPermission(): Promise<boolean> {
  if (Platform.OS === 'android') {
    const granted = await PermissionsAndroid.request(
      PermissionsAndroid.PERMISSIONS.RECORD_AUDIO
    );
    return granted === PermissionsAndroid.RESULTS.GRANTED;
  }
  return true; // iOS handles via Info.plist
}

async function checkModelsReady(): Promise<boolean> {
  for (const file of ALL_MODEL_FILES) {
    if (!(await RNFS.exists(file.dest))) return false;
  }
  return true;
}

/**
 * Download a single model file to disk.
 * - Binary ONNX files: RNFS.downloadFile streams directly to disk (avoids loading
 *   90 MB into JS memory) and provides native progress callbacks.
 * - Small text files: react-native-nitro-fetch reads into memory, RNFS writes to disk.
 */
async function downloadModelFile(
  file: ModelFile,
  onProgress: (pct: number) => void
): Promise<void> {
  if (file.useNitroFetch) {
    onProgress(0);
    const res = await nitroFetch(file.url);
    if (!res.ok) throw new Error(`HTTP ${res.status} downloading ${file.label}`);
    const text = await res.text();
    await RNFS.writeFile(file.dest, text, 'utf8');
    onProgress(1);
  } else {
    const { promise } = RNFS.downloadFile({
      fromUrl: file.url,
      toFile: file.dest,
      background: true,
      progress: (res: { bytesWritten: number; contentLength: number }) => {
        if (res.contentLength > 0) onProgress(res.bytesWritten / res.contentLength);
      },
    });
    const result = await promise;
    if (result.statusCode !== 200) {
      throw new Error(`HTTP ${result.statusCode} downloading ${file.label}`);
    }
    onProgress(1);
  }
}

// ─── DOWNLOAD STATE ───────────────────────────────────────────────────────────
type DownloadPhase =
  | { status: 'checking' }
  | { status: 'ready' }
  | { status: 'needed' }
  | { status: 'downloading'; currentFile: string; overallPct: number }
  | { status: 'error'; message: string };

// ─── APP COMPONENT ───────────────────────────────────────────────────────────
function App(): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';
  const colors = isDarkMode
    ? { bg: '#1a1a2e', card: '#16213e', text: '#e0e0e0', accent: '#0f3460', button: '#533483', muted: '#888' }
    : { bg: '#f5f5f5', card: '#ffffff', text: '#1a1a2e', accent: '#3282b8', button: '#0f3460', muted: '#666' };

  // ─── Download state ───────────────────────────────────────────────────────
  const [download, setDownload] = useState<DownloadPhase>({ status: 'checking' });

  useEffect(() => {
    checkModelsReady().then(ready =>
      setDownload({ status: ready ? 'ready' : 'needed' })
    );
  }, []);

  const startDownload = useCallback(async () => {
    try {
      await RNFS.mkdir(WHISPER_DIR);

      for (let i = 0; i < ALL_MODEL_FILES.length; i++) {
        const file = ALL_MODEL_FILES[i];
        setDownload({
          status: 'downloading',
          currentFile: file.label,
          overallPct: i / ALL_MODEL_FILES.length,
        });
        await downloadModelFile(file, (filePct) => {
          setDownload({
            status: 'downloading',
            currentFile: file.label,
            overallPct: (i + filePct) / ALL_MODEL_FILES.length,
          });
        });
      }

      setDownload({ status: 'ready' });
    } catch (e) {
      setDownload({ status: 'error', message: String(e) });
    }
  }, []);

  const retryDownload = useCallback(async () => {
    // Remove partial files before retrying
    try {
      await RNFS.unlink(MODELS_DIR);
    } catch {
      // Directory may not exist yet — that's fine
    }
    setDownload({ status: 'needed' });
  }, []);

  const modelsReady = download.status === 'ready';

  // ─── STT state ────────────────────────────────────────────────────────────
  const [sttStatus, setSttStatus] = useState<'idle' | 'listening' | 'initializing'>('idle');
  const [transcripts, setTranscripts] = useState<string[]>([]);
  const sttRef = useRef<NitroSTT | null>(null);

  // ─── TTS state ────────────────────────────────────────────────────────────
  const [ttsStatus, setTtsStatus] = useState<'idle' | 'speaking' | 'initializing'>('idle');
  const [ttsText, setTtsText] = useState('Hello! This is a test of on-device text to speech.');
  const [ttsInfo, setTtsInfo] = useState('');
  const ttsRef = useRef<NitroTTS | null>(null);

  // ─── STT ──────────────────────────────────────────────────────────────────
  const startSTT = useCallback(async () => {
    try {
      const hasPermission = await requestMicPermission();
      if (!hasPermission) {
        setTranscripts(prev => [...prev, '[Microphone permission denied]']);
        return;
      }

      setSttStatus('initializing');
      setTranscripts([]);

      const stt = await NitroSTT.create(STT_CONFIG);
      sttRef.current = stt;

      await stt.startVADGated(VAD_MODEL_PATH, {
        onTranscript: (text: string) => {
          console.log('Transcript:', text);
          setTranscripts(prev => [...prev, text]);
        },
      });

      setSttStatus('listening');
    } catch (error) {
      setSttStatus('idle');
      setTranscripts(prev => [...prev, `[Error: ${error}]`]);
    }
  }, []);

  const stopSTT = useCallback(async () => {
    try {
      if (sttRef.current) {
        sttRef.current.stopMic();
        await sttRef.current.stop();
        await sttRef.current.destroy();
        sttRef.current = null;
      }
    } finally {
      setSttStatus('idle');
    }
  }, []);

  // ─── TTS ──────────────────────────────────────────────────────────────────
  const startTTS = useCallback(async () => {
    try {
      setTtsStatus('initializing');

      if (!ttsRef.current) {
        const tts = await NitroTTS.create(TTS_CONFIG);
        ttsRef.current = tts;
        setTtsInfo(`Sample Rate: ${tts.sampleRate}Hz | Speakers: ${tts.numSpeakers}`);
      }

      setTtsStatus('speaking');

      await ttsRef.current.speak(ttsText, {
        onAudioChunk: (_samples: ArrayBuffer, sampleRate: number) => {
          setTtsInfo(`Generating... (${sampleRate}Hz)`);
        },
        onComplete: () => {
          setTtsInfo('Generation complete');
        },
      });

      setTtsStatus('idle');
    } catch (error) {
      setTtsStatus('idle');
      setTtsInfo(`Error: ${error}`);
    }
  }, [ttsText]);

  const stopTTS = useCallback(async () => {
    try {
      await ttsRef.current?.stop();
    } finally {
      setTtsStatus('idle');
    }
  }, []);

  // ─── RENDER ───────────────────────────────────────────────────────────────
  return (
    <SafeAreaView edges={['bottom', 'top']} style={[styles.container, { backgroundColor: colors.bg }]}>
      <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
      <ScrollView contentContainerStyle={styles.scrollContent}>
        <Text style={[styles.title, { color: colors.text }]}>
          NitroVoice Example
        </Text>

        {/* ── Model Download Card ── */}
        <View style={[styles.card, { backgroundColor: colors.card }]}>
          <Text style={[styles.cardTitle, { color: colors.text }]}>
            On-Device Models
          </Text>

          {download.status === 'checking' && (
            <View style={styles.row}>
              <ActivityIndicator color={colors.accent} />
              <Text style={[styles.statusText, { color: colors.muted, marginLeft: 8 }]}>
                Checking for downloaded models…
              </Text>
            </View>
          )}

          {download.status === 'needed' && (
            <>
              <Text style={[styles.modelNote, { color: colors.muted }]}>
                Downloads Whisper Tiny EN (int8) + Silero VAD — ~103 MB total.
              </Text>
              <TouchableOpacity
                style={[styles.button, { backgroundColor: colors.button }]}
                onPress={startDownload}
              >
                <Text style={styles.buttonText}>Download Models</Text>
              </TouchableOpacity>
            </>
          )}

          {download.status === 'downloading' && (
            <>
              <Text style={[styles.statusText, { color: colors.accent }]}>
                {download.currentFile}
              </Text>
              <View style={[styles.progressBar, { backgroundColor: colors.accent + '33' }]}>
                <View
                  style={[
                    styles.progressFill,
                    { backgroundColor: colors.accent, width: `${Math.round(download.overallPct * 100)}%` },
                  ]}
                />
              </View>
              <Text style={[styles.statusText, { color: colors.muted }]}>
                {Math.round(download.overallPct * 100)}% overall
              </Text>
            </>
          )}

          {download.status === 'ready' && (
            <Text style={[styles.statusText, { color: '#27ae60' }]}>
              ✓ Models ready — STT enabled below
            </Text>
          )}

          {download.status === 'error' && (
            <>
              <Text style={[styles.statusText, { color: '#c0392b' }]}>
                {download.message}
              </Text>
              <TouchableOpacity
                style={[styles.button, { backgroundColor: '#c0392b' }]}
                onPress={retryDownload}
              >
                <Text style={styles.buttonText}>Retry</Text>
              </TouchableOpacity>
            </>
          )}
        </View>

        {/* ── STT Card ── */}
        <View style={[styles.card, { backgroundColor: colors.card }]}>
          <Text style={[styles.cardTitle, { color: colors.text }]}>
            Speech-to-Text (VAD-gated Whisper)
          </Text>

          <TouchableOpacity
            style={[
              styles.button,
              {
                backgroundColor: sttStatus === 'listening' ? '#c0392b' : colors.button,
                opacity: modelsReady ? 1 : 0.4,
              },
            ]}
            onPress={sttStatus === 'listening' ? stopSTT : startSTT}
            disabled={!modelsReady || sttStatus === 'initializing'}
          >
            <Text style={styles.buttonText}>
              {sttStatus === 'idle' && (modelsReady ? 'Start Listening' : 'Models required')}
              {sttStatus === 'initializing' && 'Initializing…'}
              {sttStatus === 'listening' && 'Stop Listening'}
            </Text>
          </TouchableOpacity>

          {sttStatus === 'listening' && (
            <Text style={[styles.statusText, { color: colors.accent }]}>
              Listening — speak, then pause for transcript
            </Text>
          )}

          <View style={styles.transcriptContainer}>
            {transcripts.length === 0 ? (
              <Text style={[styles.placeholder, { color: colors.muted }]}>
                Transcripts will appear here…
              </Text>
            ) : (
              transcripts.map((t, i) => (
                <Text key={i} style={[styles.transcript, { color: colors.text }]}>
                  {t}
                </Text>
              ))
            )}
          </View>
        </View>

        {/* ── TTS Card ── */}
        <View style={[styles.card, { backgroundColor: colors.card }]}>
          <Text style={[styles.cardTitle, { color: colors.text }]}>
            Text-to-Speech (Kokoro)
          </Text>

          <Text style={[styles.modelNote, { color: colors.muted }]}>
            Requires a Kokoro model placed at:{'\n'}
            <Text style={{ fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace', fontSize: 11 }}>
              {TTS_CONFIG.modelDir}
            </Text>
          </Text>

          <TextInput
            style={[styles.input, { color: colors.text, borderColor: colors.accent }]}
            value={ttsText}
            onChangeText={setTtsText}
            placeholder="Enter text to speak…"
            placeholderTextColor={isDarkMode ? '#666' : '#999'}
            multiline
          />

          <TouchableOpacity
            style={[
              styles.button,
              { backgroundColor: ttsStatus === 'speaking' ? '#c0392b' : colors.button },
            ]}
            onPress={ttsStatus === 'speaking' ? stopTTS : startTTS}
            disabled={ttsStatus === 'initializing'}
          >
            <Text style={styles.buttonText}>
              {ttsStatus === 'idle' && 'Speak'}
              {ttsStatus === 'initializing' && 'Initializing…'}
              {ttsStatus === 'speaking' && 'Stop'}
            </Text>
          </TouchableOpacity>

          {ttsInfo !== '' && (
            <Text style={[styles.statusText, { color: colors.accent }]}>
              {ttsInfo}
            </Text>
          )}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  scrollContent: {
    padding: 20,
    paddingBottom: 40,
  },
  title: {
    fontSize: 28,
    fontWeight: 'bold',
    marginBottom: 20,
    textAlign: 'center',
  },
  card: {
    borderRadius: 12,
    padding: 20,
    marginBottom: 20,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.1,
    shadowRadius: 4,
    elevation: 3,
  },
  cardTitle: {
    fontSize: 18,
    fontWeight: '600',
    marginBottom: 16,
  },
  button: {
    borderRadius: 8,
    paddingVertical: 14,
    paddingHorizontal: 24,
    alignItems: 'center',
    marginBottom: 12,
  },
  buttonText: {
    color: '#ffffff',
    fontSize: 16,
    fontWeight: '600',
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    marginBottom: 8,
  },
  statusText: {
    fontSize: 13,
    textAlign: 'center',
    marginBottom: 8,
  },
  modelNote: {
    fontSize: 13,
    marginBottom: 12,
    lineHeight: 18,
  },
  progressBar: {
    height: 6,
    borderRadius: 3,
    overflow: 'hidden',
    marginBottom: 6,
  },
  progressFill: {
    height: '100%',
    borderRadius: 3,
  },
  transcriptContainer: {
    marginTop: 8,
    minHeight: 60,
  },
  transcript: {
    fontSize: 15,
    lineHeight: 22,
    marginBottom: 6,
  },
  placeholder: {
    fontSize: 14,
    fontStyle: 'italic',
    opacity: 0.5,
  },
  input: {
    borderWidth: 1,
    borderRadius: 8,
    padding: 12,
    fontSize: 15,
    marginBottom: 12,
    minHeight: 80,
    textAlignVertical: 'top',
  },
});

export default App;
