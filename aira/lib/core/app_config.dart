import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-editable connection settings. The API key is stored separately in the
/// platform keystore and never written to SharedPreferences or logs.
class AppSettings {
  const AppSettings({
    this.serverUrl = 'http://127.0.0.1:8000',
    this.apiKey = '',
    this.model = '',
    this.language = 'bn',
    this.autoSpeak = false,
    this.voiceId = '',
    this.speechRate = 1.0,
  });

  static const defaults = AppSettings();

  final String serverUrl;
  final String apiKey;
  final String model;
  final String language;
  final bool autoSpeak;
  final String voiceId;
  final double speechRate;

  String get normalizedBaseUrl =>
      serverUrl.trim().replaceAll(RegExp(r'/+$'), '');

  AppSettings copyWith({
    String? serverUrl,
    String? apiKey,
    String? model,
    String? language,
    bool? autoSpeak,
    String? voiceId,
    double? speechRate,
  }) {
    return AppSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      language: language ?? this.language,
      autoSpeak: autoSpeak ?? this.autoSpeak,
      voiceId: voiceId ?? this.voiceId,
      speechRate: speechRate ?? this.speechRate,
    );
  }
}

class SettingsRepository {
  SettingsRepository({
    FlutterSecureStorage? secureStorage,
    Future<SharedPreferences> Function()? prefsFactory,
  })  : _secure = secureStorage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            ),
        _prefsFactory = prefsFactory ?? SharedPreferences.getInstance;

  final FlutterSecureStorage _secure;
  final Future<SharedPreferences> Function() _prefsFactory;

  static const _kServerUrl = 'server_url';
  static const _kModel = 'model';
  static const _kLanguage = 'language';
  static const _kAutoSpeak = 'auto_speak';
  static const _kVoiceId = 'voice_id';
  static const _kSpeechRate = 'speech_rate';
  static const _kApiKey = 'openjarvis_api_key';

  Future<AppSettings> load() async {
    final prefs = await _prefsFactory();
    String key;
    try {
      key = await _secure.read(key: _kApiKey) ?? '';
    } catch (_) {
      key = ''; // e.g. unsupported secure storage on an exotic platform
    }
    return AppSettings(
      serverUrl: prefs.getString(_kServerUrl) ?? AppSettings.defaults.serverUrl,
      apiKey: key,
      model: prefs.getString(_kModel) ?? '',
      language: prefs.getString(_kLanguage) ?? 'bn',
      autoSpeak: prefs.getBool(_kAutoSpeak) ?? false,
      voiceId: prefs.getString(_kVoiceId) ?? '',
      speechRate: prefs.getDouble(_kSpeechRate) ?? 1.0,
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await _prefsFactory();
    await Future.wait([
      prefs.setString(_kServerUrl, settings.normalizedBaseUrl),
      prefs.setString(_kModel, settings.model),
      prefs.setString(_kLanguage, settings.language),
      prefs.setBool(_kAutoSpeak, settings.autoSpeak),
      prefs.setString(_kVoiceId, settings.voiceId),
      prefs.setDouble(_kSpeechRate, settings.speechRate),
    ]);
    try {
      if (settings.apiKey.isEmpty) {
        await _secure.delete(key: _kApiKey);
      } else {
        await _secure.write(key: _kApiKey, value: settings.apiKey);
      }
    } catch (_) {
      // Keep non-secret settings usable even when the keystore is unavailable.
    }
  }
}
