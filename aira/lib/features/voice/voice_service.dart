import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../../core/api_client.dart';

class VoiceException implements Exception {
  const VoiceException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Encapsulates microphone capture, server-side STT and server-side TTS.
class VoiceService {
  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  String? _recordingPath;

  bool _recording = false;
  bool get isRecording => _recording;

  Future<void> startRecording() async {
    if (_recording) return;
    try {
      if (!kIsWeb) {
        final status = await Permission.microphone.request();
        if (!status.isGranted) {
          throw const VoiceException('Microphone permission was denied');
        }
      }
      if (!await _recorder.hasPermission()) {
        throw const VoiceException('Recorder permission was denied');
      }

      String? path;
      if (!kIsWeb) {
        final dir = await getTemporaryDirectory();
        path = '${dir.path}/aira_voice.m4a';
      }
      _recordingPath = await _recorder.start(
        const RecordConfig(encoder: AudioEncoder.aacLc, autoGain: true),
        path: path,
      );
      _recording = true;
    } on VoiceException {
      rethrow;
    } catch (e) {
      throw VoiceException('Could not start recording: $e');
    }
  }

  Future<String?> stopRecording() async {
    if (!_recording) return null;
    final path = await _recorder.stop();
    _recording = false;
    _recordingPath = null;
    return path;
  }

  Future<String> transcribe(
    ApiClient api, {
    required String path,
    String? language,
  }) {
    final filename = path.split(RegExp(r'[/?#]')).last;
    return api.transcribe(
      audioPath: path,
      language: language,
      filename: filename.endsWith('.m4a') ? filename : 'voice.m4a',
    );
  }

  Future<void> speak(Uint8List audio) async {
    if (audio.isEmpty) return;
    await _player.stop();
    await _player.setAudioSource(
      AudioSource.uri(Uri.dataFromBytes(audio, mimeType: 'audio/wav')),
    );
    await _player.play();
  }

  Future<void> stopPlaying() => _player.stop();

  Future<void> dispose() async {
    if (_recording) await _recorder.stop();
    await _recorder.dispose();
    await _player.dispose();
  }
}
