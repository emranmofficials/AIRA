import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'app_config.dart';
import 'models.dart';
import 'sse.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Thin client for the OpenJarvis REST API.
///
/// All model execution, tool use, memory and scheduling happen on the server;
/// this class only moves JSON, SSE frames and audio across the wire.
class ApiClient {
  ApiClient(AppSettings settings)
      : _settings = settings,
        _dio = Dio(BaseOptions(
          baseUrl: settings.normalizedBaseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 120),
          headers: <String, dynamic>{
            'Content-Type': 'application/json',
            if (settings.apiKey.isNotEmpty)
              'Authorization': 'Bearer ${settings.apiKey}',
          },
        ));

  final AppSettings _settings;
  final Dio _dio;

  String get baseUrl => _settings.normalizedBaseUrl;

  void dispose() => _dio.close();

  Future<Map<String, dynamic>> health() => getJson('/health');

  Future<Map<String, dynamic>> getJson(String path) async {
    try {
      final response = await _dio.get<dynamic>(path);
      return _asMap(response.data);
    } catch (e) {
      throw _wrap(e);
    }
  }

  Future<Map<String, dynamic>> postJson(String path, Object body) async {
    try {
      final response = await _dio.post<dynamic>(path, data: body);
      return _asMap(response.data);
    } catch (e) {
      throw _wrap(e);
    }
  }

  Future<Map<String, dynamic>> patchJson(String path, Object body) async {
    try {
      final response = await _dio.patch<dynamic>(path, data: body);
      return _asMap(response.data);
    } catch (e) {
      throw _wrap(e);
    }
  }

  Future<void> delete(String path) async {
    try {
      await _dio.delete<dynamic>(path);
    } catch (e) {
      throw _wrap(e);
    }
  }

  Future<List<String>> listModels() async {
    final data = await getJson('/v1/models');
    final items = data['data'];
    if (items is! List) return const [];
    final models = <String>[];
    for (final item in items) {
      if (item is Map && item['id'] is String) models.add(item['id'] as String);
    }
    return models;
  }

  /// Stream a chat completion. Tool execution happens inside the server agent,
  /// so no tool loop is needed here.
  Stream<ChatChunk> streamChat({
    required List<ChatMessage> messages,
    String? model,
    int maxTokens = 1024,
  }) async* {
    final selected = (model ?? _settings.model).trim();
    final actualModel = selected.isNotEmpty ? selected : await _defaultModel();
    final body = <String, dynamic>{
      'model': actualModel,
      'messages': messages.map((m) => m.toJson()).toList(growable: false),
      'stream': true,
      'max_tokens': maxTokens,
    };

    late final Response<ResponseBody> response;
    try {
      response = await _dio.post<ResponseBody>(
        '/v1/chat/completions',
        data: body,
        options: Options(responseType: ResponseType.stream),
      );
    } catch (e) {
      throw _wrap(e);
    }

    final stream = response.data?.stream;
    if (stream == null) throw const ApiException('Empty streaming response');

    final decoder = SseDecoder();
    await for (final text in stream.transform(utf8.decoder)) {
      for (final event in decoder.feed(text)) {
        if (event.data == '[DONE]') return;
        final chunk = ChatChunk.fromSse(event);
        if (!chunk.isEmpty) yield chunk;
      }
    }
  }

  Future<String> _defaultModel() async {
    final models = await listModels();
    if (models.isEmpty) {
      throw const ApiException('The server reports no available models');
    }
    return models.first;
  }

  Future<String> transcribe({
    required String audioPath,
    String? language,
    String filename = 'audio.m4a',
  }) async {
    try {
      MultipartFile file;
      // record's web backend yields blob:/http URLs instead of local paths.
      if (audioPath.startsWith('blob:') || audioPath.startsWith('http')) {
        final bytes = await _dio.get<List<int>>(
          audioPath,
          options: Options(responseType: ResponseType.bytes),
        );
        file = MultipartFile.fromBytes(bytes.data ?? <int>[], filename: filename);
      } else {
        file = await MultipartFile.fromFile(audioPath, filename: filename);
      }
      final form = FormData.fromMap(<String, dynamic>{
        'file': file,
        if (language != null && language.isNotEmpty) 'language': language,
      });
      final response = await _dio.post<dynamic>(
        '/v1/speech/transcribe',
        data: form,
      );
      final text = _asMap(response.data)['text'];
      return text is String ? text : '';
    } catch (e) {
      throw _wrap(e);
    }
  }

  Future<Uint8List> synthesize({
    required String text,
    String? voiceId,
    double? speed,
  }) async {
    try {
      final response = await _dio.post<List<int>>(
        '/v1/speech/synthesize',
        data: <String, dynamic>{
          'text': text,
          if (voiceId != null && voiceId.isNotEmpty) 'voice_id': voiceId,
          if (speed != null) 'speed': speed,
        },
        options: Options(responseType: ResponseType.bytes),
      );
      return Uint8List.fromList(response.data ?? <int>[]);
    } catch (e) {
      throw _wrap(e);
    }
  }

  Future<Map<String, dynamic>> speechHealth() => getJson('/v1/speech/health');

  Future<List<MemoryFact>> searchMemory(String query, {int topK = 8}) async {
    final data = await postJson('/v1/memory/search', <String, dynamic>{
      'query': query,
      'top_k': topK,
    });
    return MemoryFact.fromJsonList(data['results']);
  }

  Future<void> storeMemory(String content) async {
    await postJson('/v1/memory/store', <String, dynamic>{
      'content': content,
      'metadata': <String, dynamic>{'source': 'aira_flutter'},
    });
  }

  Future<Map<String, dynamic>> memoryStats() => getJson('/v1/memory/stats');

  Future<Map<String, dynamic>> memoryConfig() => getJson('/v1/memory/config');

  Future<List<ManagedAgent>> listAgents() async {
    final data = await getJson('/v1/managed-agents');
    return ManagedAgent.fromJsonList(data['agents']);
  }

  Future<ManagedAgent> createAgent({
    required String name,
    required String instruction,
    required String scheduleType,
    required String scheduleValue,
    String agentType = 'monitor_operative',
    String? timezone,
  }) async {
    final config = <String, dynamic>{
      'instruction': instruction,
      'schedule_type': scheduleType,
      'schedule_value': scheduleValue,
      'max_turns': 10,
    };
    if (timezone != null && timezone.isNotEmpty) {
      config['timezone'] = timezone;
    }
    final data = await postJson('/v1/managed-agents', <String, dynamic>{
      'name': name,
      'agent_type': agentType,
      'config': config,
    });
    return ManagedAgent(
      id: data['id'] as String? ?? '',
      name: data['name'] as String? ?? name,
      agentType: data['agent_type'] as String? ?? agentType,
      scheduleType: scheduleType,
      scheduleValue: scheduleValue,
      status: data['status'] as String? ?? 'idle',
      instruction: instruction,
    );
  }

  Future<void> pauseAgent(String id) =>
      postJson('/v1/managed-agents/$id/pause', <String, dynamic>{});

  Future<void> resumeAgent(String id) =>
      postJson('/v1/managed-agents/$id/resume', <String, dynamic>{});

  Future<void> deleteAgent(String id) =>
      delete('/v1/managed-agents/$id');

  static Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return const <String, dynamic>{};
  }

  static ApiException _wrap(Object error) {
    if (error is ApiException) return error;
    if (error is DioException) {
      final raw = error.response?.data;
      Object? detail;
      if (raw is Map) {
        detail = raw['detail'] ?? raw['message'];
      }
      final message = detail?.toString() ?? error.message ?? 'Request failed';
      return ApiException(message, statusCode: error.response?.statusCode);
    }
    return ApiException(error.toString());
  }
}
