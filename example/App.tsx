/**
 * NitroVoice Example App
 * Demonstrates VAD-gated Whisper STT and Kokoro TTS
 */

import React, { useState, useRef, useCallback } from 'react';
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
} from 'react-native';
import { NitroSTT, NitroTTS, NitroVAD } from 'react-native-nitro-voice';
import type { STTConfig, TTSConfig, VADConfig } from 'react-native-nitro-voice';
import { SafeAreaView } from 'react-native-safe-area-context';

// ─── IMPORTANT ──────────────────────────────────────────────────────────────
// Set these paths to your downloaded model directories.
// Models are NOT bundled — you must download them separately.
// See README for model directory structure requirements.
const MODEL_DIR = Platform.select({
  ios: `${/* MainBundle path — set at runtime */ ''}`,
  android: '/data/local/tmp/models', // or wherever you place model files
}) ?? '';

const STT_CONFIG: STTConfig = {
  modelDir: `${MODEL_DIR}/whisper`,
  type: 'whisper',
  language: 'en',
};

const TTS_CONFIG: TTSConfig = {
  modelDir: `${MODEL_DIR}/kokoro`,
  type: 'kokoro',
  speed: 1.0,
};

const VAD_MODEL_PATH = `${MODEL_DIR}/silero_vad.onnx`;

async function requestMicPermission(): Promise<boolean> {
  if (Platform.OS === 'android') {
    const granted = await PermissionsAndroid.request(
      PermissionsAndroid.PERMISSIONS.RECORD_AUDIO
    );
    return granted === PermissionsAndroid.RESULTS.GRANTED;
  }
  return true; // iOS handles via Info.plist
}

function App(): React.JSX.Element {
  const isDarkMode = useColorScheme() === 'dark';
  const colors = isDarkMode
    ? { bg: '#1a1a2e', card: '#16213e', text: '#e0e0e0', accent: '#0f3460', button: '#533483' }
    : { bg: '#f5f5f5', card: '#ffffff', text: '#1a1a2e', accent: '#3282b8', button: '#0f3460' };

  // STT state
  const [sttStatus, setSttStatus] = useState<'idle' | 'listening' | 'initializing'>('idle');
  const [transcripts, setTranscripts] = useState<string[]>([]);
  const sttRef = useRef<NitroSTT | null>(null);

  // TTS state
  const [ttsStatus, setTtsStatus] = useState<'idle' | 'speaking' | 'initializing'>('idle');
  const [ttsText, setTtsText] = useState('Hello! This is a test of on-device text to speech.');
  const [ttsInfo, setTtsInfo] = useState('');
  const ttsRef = useRef<NitroTTS | null>(null);

  // ─── STT ────────────────────────────────────────────────────────────────

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
          setTranscripts(prev => [...prev, text]);
        },
      });

      await stt.startMic();
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
      setSttStatus('idle');
    } catch (error) {
      setSttStatus('idle');
    }
  }, []);

  // ─── TTS ────────────────────────────────────────────────────────────────

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
          // In a real app, feed these PCM chunks to an audio player
          // e.g. expo-av, react-native-audio-api, etc.
          setTtsInfo(prev => `Generating... (${sampleRate}Hz)`);
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
      if (ttsRef.current) {
        await ttsRef.current.stop();
      }
      setTtsStatus('idle');
    } catch (error) {
      setTtsStatus('idle');
    }
  }, []);

  return (
    <SafeAreaView style={[styles.container, { backgroundColor: colors.bg }]}>
      <StatusBar barStyle={isDarkMode ? 'light-content' : 'dark-content'} />
      <ScrollView contentContainerStyle={styles.scrollContent}>
        <Text style={[styles.title, { color: colors.text }]}>
          NitroVoice Example
        </Text>

        {/* STT Section */}
        <View style={[styles.card, { backgroundColor: colors.card }]}>
          <Text style={[styles.cardTitle, { color: colors.text }]}>
            Speech-to-Text (VAD-gated Whisper)
          </Text>

          <TouchableOpacity
            style={[
              styles.button,
              { backgroundColor: sttStatus === 'listening' ? '#c0392b' : colors.button },
            ]}
            onPress={sttStatus === 'listening' ? stopSTT : startSTT}
            disabled={sttStatus === 'initializing'}
          >
            <Text style={styles.buttonText}>
              {sttStatus === 'idle' && 'Start Listening'}
              {sttStatus === 'initializing' && 'Initializing...'}
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
              <Text style={[styles.placeholder, { color: colors.text }]}>
                Transcripts will appear here...
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

        {/* TTS Section */}
        <View style={[styles.card, { backgroundColor: colors.card }]}>
          <Text style={[styles.cardTitle, { color: colors.text }]}>
            Text-to-Speech (Kokoro)
          </Text>

          <TextInput
            style={[styles.input, { color: colors.text, borderColor: colors.accent }]}
            value={ttsText}
            onChangeText={setTtsText}
            placeholder="Enter text to speak..."
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
              {ttsStatus === 'initializing' && 'Initializing...'}
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
  statusText: {
    fontSize: 13,
    textAlign: 'center',
    marginBottom: 8,
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
